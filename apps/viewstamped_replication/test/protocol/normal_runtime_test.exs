defmodule ViewstampedReplication.Protocol.NormalRuntimeTest do
  use ExUnit.Case, async: false

  alias ViewstampedReplication.{Configuration, Log, LogEntry, Member, Protocol, Request}
  alias ViewstampedReplication.Protocol.{Commit, Envelope, Prepare, PrepareOk, State}

  @ids [:primary, :backup_a, :backup_b]
  @history_functions [
    {Protocol, :step, 2},
    {Protocol, :runtime_state, 1},
    {Protocol, :index_applied_requests, 3},
    {Log, :canonical, 1},
    {Log, :indexed, 1}
  ]

  test "legal three-voter writes preserve exhaustive effects without scanning retained history" do
    rows =
      for count <- [1_000, 10_000] do
        nodes = nodes(count)

        with_trace(fn session ->
          sim = %{nodes: nodes, queue: [], samples: [], replies: [], applies: []}

          final =
            Enum.reduce((count + 1)..(count + 5), sim, fn number, sim ->
              sim
              |> deliver(:primary, {:client_request, :route, request(:writer, number)}, session)
              |> drain(session)
            end)

          assert length(final.replies) == 5
          assert length(final.applies) == 15
          assert length(final.samples) == 50

          for {_id, node} <- final.nodes do
            assert node.state.op_number == count + 5
            assert node.state.commit_number == count + 5
            assert node.state.applied_number == count + 5
            assert node.state.applying_number == nil
            assert node.state.pending_clients == %{}
            assert Enum.take(Log.to_list(node.state.log), count) == entries(count)
            assert Protocol.assert_invariants!(node.state) == node.state
          end

          Enum.group_by(final.samples, & &1.event, & &1.reductions)
        end)
      end

    [small, large] = rows

    for {event, samples} <- small do
      # Ten times the retained history must not produce its former linear work.
      assert median(Map.fetch!(large, event)) < median(samples) * 4 + 2_000,
             inspect({event, rows})
    end
  end

  test "pipelined appends, cumulative quorum acknowledgements and chained applies retain parity" do
    primary = Map.fetch!(nodes(20), :primary)
    backup = Map.fetch!(nodes(20), :backup_a)

    with_trace(fn session ->
      {primary, first, _} =
        owned_step(primary, {:client_request, :route, request(:one, 1)}, session)

      {primary, second, _} =
        owned_step(primary, {:client_request, :route, request(:two, 1)}, session)

      prepare_one = payload(first, Prepare)
      prepare_two = payload(second, Prepare)
      {backup, _, _} = owned_step(backup, peer(:primary, prepare_one), session)
      {backup, _, _} = owned_step(backup, peer(:primary, prepare_two), session)

      {primary, committed, _} =
        owned_step(primary, peer(:backup_a, %PrepareOk{view_number: 0, op_number: 22}), session)

      assert primary.state.commit_number == 22
      assert primary.state.applying_number == 21

      assert [{:apply, %LogEntry{op_number: 21}}] =
               Enum.filter(committed, &match?({:apply, _}, &1))

      {primary, first_applied, _} =
        owned_step(primary, {:state_machine_applied, 21, :first}, session)

      assert primary.state.applying_number == 22

      assert [{:apply, %LogEntry{op_number: 22}}] =
               Enum.filter(first_applied, &match?({:apply, _}, &1))

      {primary, _, _} = owned_step(primary, {:state_machine_applied, 22, :second}, session)
      assert primary.state.applied_request_index.one == %{1 => 21}
      assert primary.state.applied_request_index.two == %{1 => 22}

      # An exact retained Prepare may carry a newer commit while the backup is
      # already applying; neither delivery replaces the retained log.
      {backup, _, _} =
        owned_step(backup, peer(:primary, %Commit{view_number: 0, commit_number: 21}), session)

      committed_prepare = %{prepare_two | commit_number: 22}
      {backup, _, _} = owned_step(backup, peer(:primary, committed_prepare), session)
      {backup, _, _} = owned_step(backup, peer(:primary, committed_prepare), session)
      assert backup.state.applying_number == 21
      {backup, _, _} = owned_step(backup, {:state_machine_applied, 21, :first}, session)
      {backup, _, _} = owned_step(backup, {:state_machine_applied, 22, :second}, session)
      assert backup.state.applied_number == 22

      {primary, retry, _} =
        owned_step(primary, {:client_request, :retry, request(:two, 1)}, session)

      assert [{:reply, :retry, %{result: :second}}] = retry
      assert primary.state.op_number == 22
    end)
  end

  test "normal envelopes retain identity checks and exceptional events retain exhaustive parity" do
    node = Map.fetch!(nodes(10), :backup_a)
    prepare = %Prepare{view_number: 0, op_number: 11, commit_number: 10, entry: entry(11)}
    {:peer_message, _, envelope} = peer(:primary, prepare)

    with_trace(fn session ->
      for invalid <- [
            %{envelope | protocol_version: 99},
            %{envelope | group_id: :other},
            %{envelope | configuration_hash: :other},
            %{envelope | from: :backup_b}
          ] do
        {unchanged, [], _} = owned_step(node, {:peer_message, :primary, invalid}, session)
        assert unchanged.state == node.state
      end

      outsider = %{envelope | from: :outsider, payload: %PrepareOk{view_number: 0, op_number: 10}}
      {unchanged, [], _} = owned_step(node, {:peer_message, :outsider, outsider}, session)
      assert unchanged.state == node.state
      {accepted, _, _} = owned_step(node, peer(:primary, prepare), session)
      {duplicate, _, _} = owned_step(accepted, peer(:primary, prepare), session)
      assert duplicate.state.log == accepted.state.log
      {_, [], _} = owned_step(node, peer(:backup_b, prepare), session)
    end)

    for event <- [
          peer(:backup_a, %{prepare | view_number: 1}),
          peer(:backup_a, %Commit{view_number: 1, commit_number: 12}),
          peer(:primary, %{prepare | view_number: -1}),
          peer(:primary, %{prepare | op_number: 12, entry: entry(12)}),
          peer(:primary, %{prepare | op_number: 10, entry: %{entry(10) | operation: :conflict}}),
          peer(:primary, %{prepare | entry: %{entry(11) | view_number: 1}}),
          peer(:primary, %Commit{view_number: 0, commit_number: 12}),
          {:state_machine_applied, 12, :unexpected},
          {:snapshot_completed, 5, %{last_op_number: 5}},
          {:timeout, :primary, Map.fetch!(node.state.timer_tokens, :primary)}
        ] do
      owned_step(node, event)
    end

    {cold, _} = Protocol.runtime(State.new(configuration(:backup_a, @ids)))
    {_cold, advance} = Protocol.runtime(cold)
    owned_step(%{state: cold, advance: advance}, peer(:primary, prepare))
  end

  test "owned backup application rejects previously applied request pairs despite missing client metadata" do
    for id <- @ids do
      node = Map.fetch!(nodes(10), id)
      {state, advance} = Protocol.runtime(%{node.state | client_table: %{}})
      node = %{state: state, advance: advance}
      duplicate = %{entry(11) | request_number: 1}

      node =
        if id == :primary do
          {node, _, _} = owned_step(node, {:client_request, :route, request(:writer, 1)})

          {node, _, _} =
            owned_step(node, peer(:backup_a, %PrepareOk{view_number: 0, op_number: 11}))

          node
        else
          prepare = %Prepare{view_number: 0, op_number: 11, commit_number: 11, entry: duplicate}
          {node, _, _} = owned_step(node, peer(:primary, prepare))
          node
        end

      assert_raise ArgumentError, ~r/client_request_applied_more_than_once/, fn ->
        node.advance.({:state_machine_applied, 11, :duplicate})
      end
    end
  end

  test "actual emitted idle heartbeat tokens preserve state without retained-history work" do
    for ids <- [[:primary], @ids], count <- [1_000, 10_000] do
      node = Map.fetch!(nodes(count, ids), :primary)

      with_trace(fn session ->
        final =
          Enum.reduce(1..5, node, fn _, node ->
            token = Map.fetch!(node.state.timer_tokens, :heartbeat)
            {next, effects, _} = owned_step(node, {:timeout, :heartbeat, token}, session)

            assert [
                     {:broadcast, %Envelope{payload: %Commit{commit_number: ^count}}},
                     {:schedule_timer, :heartbeat, 500, next_token}
                   ] = effects

            refute token == next_token
            assert next.state.timer_tokens.heartbeat == next_token
            assert next.state.log == node.state.log
            assert next.state.client_table == node.state.client_table
            assert next.state.op_number == count
            assert next.state.applied_number == count
            next
          end)

        owned_step(final, {:timeout, :heartbeat, {:heartbeat, 0, -1}})
      end)
    end
  end

  defp deliver(sim, id, event, session) do
    {node, effects, sample} = owned_step(Map.fetch!(sim.nodes, id), event, session)
    sim = %{sim | nodes: Map.put(sim.nodes, id, node), samples: [sample | sim.samples]}

    Enum.reduce(effects, sim, fn
      {:broadcast, %Envelope{} = envelope}, sim ->
        queue =
          for destination <- @ids, destination != id, do: {destination, peer_envelope(envelope)}

        %{sim | queue: sim.queue ++ queue}

      {:send, destination, %Envelope{} = envelope}, sim ->
        %{sim | queue: sim.queue ++ [{destination, peer_envelope(envelope)}]}

      {:apply, %LogEntry{op_number: number}}, sim ->
        sim = %{sim | applies: [{id, number} | sim.applies]}
        deliver(sim, id, {:state_machine_applied, number, :ok}, session)

      {:reply, :route, reply}, sim ->
        assert id == :primary and reply.result == :ok
        %{sim | replies: [reply | sim.replies]}

      effect, sim when elem(effect, 0) in [:persist, :schedule_timer, :emit_telemetry] ->
        sim
    end)
  end

  defp drain(%{queue: []} = sim, _session), do: sim

  defp drain(%{queue: [{id, event} | rest]} = sim, session),
    do: sim |> Map.put(:queue, rest) |> deliver(id, event, session) |> drain(session)

  defp owned_step(node, event, session \\ nil) do
    if session, do: :trace.process(session, self(), true, [:call, :arity])
    {:reductions, before_count} = Process.info(self(), :reductions)
    {state, effects, advance} = node.advance.(event)
    {:reductions, after_count} = Process.info(self(), :reductions)

    if session do
      1 = :trace.process(session, self(), false, [:call, :arity])
      reference = :trace.delivered(session, self())
      assert_receive {:trace_delivered, _, ^reference}
      assert history_calls([]) == []
    end

    {pure, pure_effects} = Protocol.step(canonical(node.state), event)
    assert canonical(state) == pure
    assert effects == pure_effects
    assert Protocol.assert_invariants!(state) == state
    sample = %{event: phase(event), reductions: after_count - before_count}
    {%{state: state, advance: advance}, effects, sample}
  end

  defp with_trace(fun) do
    {:module, :trace} = Code.ensure_loaded(:trace)
    session = :trace.session_create(:normal_runtime, self(), [])

    try do
      for mfa <- @history_functions, do: 1 = :trace.function(session, mfa, true, [:local])
      fun.(session)
    after
      :trace.process(session, self(), false, [:call, :arity])
      true = :trace.session_destroy(session)
    end
  end

  defp history_calls(calls) do
    receive do
      {:trace, _, :call, mfa} -> history_calls([mfa | calls])
    after
      0 -> calls
    end
  end

  defp nodes(count, ids \\ @ids) do
    Map.new(ids, fn id ->
      config = configuration(id, ids)
      {:ok, log} = Log.new(entries(count))

      recovered = %{
        configuration_hash: Configuration.hash(config),
        replica_id: id,
        hard_state: %{view_number: 0, last_normal_view: 0, status: :normal},
        log: log,
        commit_number: count,
        applied_number: count,
        client_table: %{writer: %{request_number: count, status: :applied, result: :ok}}
      }

      {_empty, advance} = Protocol.runtime(State.new(config))
      {state, _, advance} = advance.({:storage_recovered, {:durable, recovered}})
      {id, %{state: state, advance: advance}}
    end)
  end

  defp configuration(id, ids),
    do:
      Configuration.new!(
        group_id: :normal_runtime,
        replica_id: id,
        members: Enum.map(ids, &%Member{id: &1, endpoint: &1})
      )

  defp peer(sender, payload) do
    envelope = %Envelope{
      protocol_version: 1,
      group_id: :normal_runtime,
      configuration_hash: Configuration.hash(configuration(:primary, @ids)),
      from: sender,
      payload: payload
    }

    {:peer_message, sender, envelope}
  end

  defp peer_envelope(%Envelope{from: sender} = envelope), do: {:peer_message, sender, envelope}
  defp canonical(state), do: %{state | log: Log.canonical(state.log)}
  defp entries(count), do: Enum.map(1..count, &entry/1)

  defp entry(number),
    do: %LogEntry{
      view_number: 0,
      op_number: number,
      client_id: :writer,
      request_number: number,
      operation: {:put, :key, :value}
    }

  defp request(client, number),
    do: %Request{client_id: client, request_number: number, operation: {:put, :key, :value}}

  defp payload(effects, module),
    do:
      Enum.find_value(effects, fn
        {:broadcast, %Envelope{payload: %{__struct__: ^module} = payload}} -> payload
        _ -> nil
      end)

  defp phase({:peer_message, _, %Envelope{payload: payload}}), do: payload.__struct__
  defp phase(event), do: elem(event, 0)
  defp median(samples), do: samples |> Enum.sort() |> Enum.at(div(length(samples), 2))
end
