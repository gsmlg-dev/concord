defmodule ViewstampedReplication.Protocol.MultivoterReadRuntimeTest do
  use ExUnit.Case, async: false

  alias ViewstampedReplication.{Configuration, Log, LogEntry, Member, Protocol, Request}

  alias ViewstampedReplication.Protocol.{
    Commit,
    Envelope,
    Prepare,
    PrepareOk,
    ReadBarrier,
    ReadBarrierOk,
    State
  }

  @ids [:primary, :backup_a, :backup_b]
  @history_functions [
    {Protocol, :step, 2},
    {Protocol, :exhaustive_runtime_step, 2},
    {Protocol, :runtime_state, 1},
    {Protocol, :index_applied_requests, 3},
    {Protocol, :assert_invariants!, 1},
    {Protocol, :assert_transition!, 2},
    {Protocol, :assert_contiguous_log!, 2},
    {Protocol, :applied_requests_indexed?, 3},
    {Protocol, :assert_committed_prefix!, 2},
    {Log, :canonical, 1},
    {Log, :indexed, 1},
    {Log, :to_list, 1}
  ]

  for count <- [1_000, 10_000] do
    @count count
    test "normal quorum reads and late acknowledgements do not rebuild #{@count} retained entries" do
      nodes = nodes(@count)

      for {_id, node} <- nodes do
        assert node.state.op_number == @count
        assert node.state.commit_number == @count
        assert node.state.applied_number == @count
        assert map_size(node.state.applied_request_index.writer) == @count
        assert Protocol.assert_invariants!(node.state) == node.state
      end

      # The fixture and write control use legal bootstrap, append, quorum and
      # apply transitions, rather than fabricating a trusted recovered state.
      {_written, controls} = write_round(nodes, @count + 1, true)
      assert_history_free(controls)
      before = retained_state(nodes)

      {nodes, effects, requested} =
        advance(nodes, :primary, {:read_request, :route, :query}, true)

      barrier = broadcast(effects, ReadBarrier)
      refute Enum.any?(effects, &match?({:read, _, _}, &1))

      {nodes, effects, first_voter} = advance(nodes, :backup_a, peer(:primary, barrier), true)
      first_ack = sent(effects, :primary, ReadBarrierOk)
      {nodes, effects, quorum} = advance(nodes, :primary, peer(:backup_a, first_ack), true)
      assert effects == [{:read, :route, :query}, {:cancel_timer, :read}]
      assert nodes.primary.state.pending_reads == %{}

      {nodes, effects, late_voter} = advance(nodes, :backup_b, peer(:primary, barrier), true)
      late_ack = sent(effects, :primary, ReadBarrierOk)
      {nodes, [], late_primary} = advance(nodes, :primary, peer(:backup_b, late_ack), true)
      {nodes, [], duplicate} = advance(nodes, :primary, peer(:backup_a, first_ack), true)

      assert_history_free([requested, first_voter, quorum, late_voter, late_primary, duplicate])
      assert retained_state(nodes) == before
    end
  end

  test "quorum acknowledgements retain membership, identity, nonce and duplicate checks" do
    nodes = nodes(10)
    {nodes, effects, requested} = advance(nodes, :primary, {:read_request, :route, :query}, true)
    barrier = broadcast(effects, ReadBarrier)
    ack = %ReadBarrierOk{view_number: 0, nonce: barrier.payload.nonce}

    # A repeated self acknowledgement cannot satisfy a three-voter quorum.
    {nodes, [], self_ack} = advance(nodes, :primary, peer(:primary, ack), true)
    assert map_size(nodes.primary.state.pending_reads) == 1

    {nodes, [], unknown_nonce} =
      advance(nodes, :primary, peer(:backup_a, %{ack | nonce: :other}), true)

    {:peer_message, _, envelope} = peer(:backup_a, ack)

    for invalid <- [
          %{envelope | protocol_version: 99},
          %{envelope | group_id: :other},
          %{envelope | configuration_hash: :other},
          %{envelope | from: :backup_b}
        ] do
      {same, [], sample} = advance(nodes, :primary, {:peer_message, :backup_a, invalid}, true)
      assert same.primary.state == nodes.primary.state
      assert_history_free([sample])
    end

    {same, [], outsider} = advance(nodes, :primary, peer(:outsider, ack), true)
    assert same.primary.state == nodes.primary.state
    {same, [], wrong_primary} = advance(nodes, :backup_b, peer(:backup_a, barrier.payload), true)
    assert same.backup_b.state == nodes.backup_b.state

    {nodes, effects, quorum} = advance(nodes, :primary, peer(:backup_a, ack), true)
    assert effects == [{:read, :route, :query}, {:cancel_timer, :read}]
    assert_history_free([requested, self_ack, unknown_nonce, outsider, wrong_primary, quorum])
    assert nodes.primary.state.pending_reads == %{}
  end

  test "same-view barriers advance only the pending suffix and preserve not-ready reads" do
    nodes = nodes(10)
    request = request(11)

    {nodes, effects, appended} =
      advance(nodes, :primary, {:client_request, :write, request}, true)

    prepare = broadcast(effects, Prepare)
    {nodes, _, prepared} = advance(nodes, :backup_a, peer(:primary, prepare), true)
    barrier = %ReadBarrier{view_number: 0, nonce: :pending, commit_number: 11}
    {nodes, effects, catching_up} = advance(nodes, :backup_a, peer(:primary, barrier), true)
    assert [{:apply, %LogEntry{op_number: 11}}] = Enum.filter(effects, &match?({:apply, _}, &1))
    assert nodes.backup_a.state.commit_number == 11
    assert nodes.backup_a.state.applied_number == 10
    assert nodes.backup_a.state.applying_number == 11

    {nodes, effects, backup_read} =
      advance(nodes, :backup_a, {:read_request, :route, :query}, true)

    assert effects == [{:read_reply, :route, {:error, {:not_primary, :primary}}}]

    ack = %PrepareOk{view_number: 0, op_number: 11}
    {nodes, _, committed} = advance(nodes, :primary, peer(:backup_a, ack), true)

    {_nodes, effects, primary_read} =
      advance(nodes, :primary, {:read_request, :route, :query}, true)

    assert effects == [{:read_reply, :route, {:error, :not_ready}}]
    assert_history_free([appended, prepared, catching_up, backup_read, committed, primary_read])
  end

  test "cold states, different views and missing-log barriers retain exhaustive validation" do
    nodes = nodes(10)

    for {id, event} <- [
          {:backup_a,
           peer(:primary, %ReadBarrier{view_number: 0, nonce: :ahead, commit_number: 11})},
          {:backup_a,
           peer(:primary, %ReadBarrier{view_number: 1, nonce: :future, commit_number: 10})},
          {:backup_a,
           peer(:primary, %ReadBarrier{view_number: -1, nonce: :stale, commit_number: 10})},
          {:primary, peer(:backup_a, %ReadBarrierOk{view_number: 1, nonce: :future})},
          {:primary, peer(:backup_a, %ReadBarrierOk{view_number: -1, nonce: :stale})}
        ] do
      {_nodes, _effects, counts} = advance(nodes, id, event, true)
      assert Map.fetch!(counts, {Protocol, :exhaustive_runtime_step, 2}) == 1
      assert Map.fetch!(counts, {Protocol, :assert_invariants!, 1}) > 0
    end

    {state, advance} = Protocol.runtime(State.new(configuration(:primary)))
    cold = %{primary: %{state: state, advance: advance}}

    {_nodes, [{:read_reply, :route, {:error, :recovering}}], counts} =
      advance(cold, :primary, {:read_request, :route, :query}, true)

    assert Map.fetch!(counts, {Protocol, :exhaustive_runtime_step, 2}) == 1
  end

  defp nodes(count) do
    nodes =
      Map.new(@ids, fn id ->
        {state, effects} =
          Protocol.step(State.new(configuration(id)), {:storage_recovered, :bootstrap})

        assert state.status == :normal
        assert Enum.any?(effects, &match?({:persist, {:hard_state, _}}, &1))
        {state, advance} = Protocol.runtime(state)
        {id, %{state: state, advance: advance}}
      end)

    Enum.reduce(1..count, nodes, fn number, nodes ->
      elem(write_round(nodes, number, false), 0)
    end)
  end

  defp write_round(nodes, number, traced) do
    {nodes, effects, s1} =
      advance(nodes, :primary, {:client_request, :write, request(number)}, traced)

    prepare = broadcast(effects, Prepare)
    {nodes, effects_a, s2} = advance(nodes, :backup_a, peer(:primary, prepare), traced)
    {nodes, effects_b, s3} = advance(nodes, :backup_b, peer(:primary, prepare), traced)
    ack_a = sent(effects_a, :primary, PrepareOk)
    ack_b = sent(effects_b, :primary, PrepareOk)
    {nodes, effects, s4} = advance(nodes, :primary, peer(:backup_a, ack_a), traced)
    commit = broadcast(effects, Commit)
    {nodes, s5} = apply_entry(nodes, :primary, effects, traced)
    {nodes, [], s6} = advance(nodes, :primary, peer(:backup_b, ack_b), traced)
    {nodes, effects, s7} = advance(nodes, :backup_a, peer(:primary, commit), traced)
    {nodes, s8} = apply_entry(nodes, :backup_a, effects, traced)
    {nodes, effects, s9} = advance(nodes, :backup_b, peer(:primary, commit), traced)
    {nodes, s10} = apply_entry(nodes, :backup_b, effects, traced)
    {nodes, [s1, s2, s3, s4, s5, s6, s7, s8, s9, s10]}
  end

  defp apply_entry(nodes, id, effects, traced) do
    [{:apply, %LogEntry{op_number: number}}] = Enum.filter(effects, &match?({:apply, _}, &1))
    {nodes, _, sample} = advance(nodes, id, {:state_machine_applied, number, :ok}, traced)
    {nodes, sample}
  end

  defp advance(nodes, id, event, traced) do
    node = Map.fetch!(nodes, id)

    {{state, effects, next}, counts} =
      if traced, do: profile(fn -> node.advance.(event) end), else: {node.advance.(event), %{}}

    if traced do
      # Reference checks deliberately run outside the owned trace bracket.
      {reference, reference_effects} = Protocol.step(canonical(node.state), event)
      assert canonical(state) == reference
      assert effects == reference_effects
      assert Protocol.assert_invariants!(state) == state
    end

    {Map.put(nodes, id, %{state: state, advance: next}), effects, counts}
  end

  defp profile(operation) do
    session = :trace.session_create(:multivoter_read_runtime, self(), [])

    try do
      for {module, _, _} = mfa <- @history_functions do
        {:module, ^module} = Code.ensure_loaded(module)
        1 = :trace.function(session, mfa, true, [:local, :call_count])
      end

      1 = :trace.process(session, self(), true, [:call, :silent])
      result = operation.()
      1 = :trace.process(session, self(), false, [:call, :silent])

      counts =
        Map.new(@history_functions, fn mfa ->
          {:call_count, count} = :trace.info(session, mfa, :call_count)
          {mfa, count}
        end)

      {result, counts}
    after
      true = :trace.session_destroy(session)
    end
  end

  defp assert_history_free(samples) do
    for counts <- samples do
      assert Enum.all?(counts, fn {_mfa, count} -> count == 0 end), inspect(counts)
    end
  end

  defp retained_state(nodes) do
    Map.new(nodes, fn {id, %{state: state}} ->
      {id,
       {canonical(state).log, state.client_table, state.applied_request_index, state.op_number,
        state.commit_number, state.applied_number}}
    end)
  end

  defp request(number),
    do: %Request{client_id: :writer, request_number: number, operation: {:put, :key, :value}}

  defp configuration(id),
    do:
      Configuration.new!(
        group_id: :multivoter_read_runtime,
        replica_id: id,
        members: Enum.map(@ids, &%Member{id: &1, endpoint: &1})
      )

  defp peer(sender, %Envelope{} = envelope), do: {:peer_message, sender, envelope}

  defp peer(sender, payload) do
    {:peer_message, sender,
     %Envelope{
       protocol_version: 1,
       group_id: :multivoter_read_runtime,
       configuration_hash: Configuration.hash(configuration(:primary)),
       from: sender,
       payload: payload
     }}
  end

  defp broadcast(effects, module) do
    [{:broadcast, %Envelope{payload: %{__struct__: ^module}} = envelope}] =
      Enum.filter(effects, &match?({:broadcast, %Envelope{payload: %{__struct__: ^module}}}, &1))

    envelope
  end

  defp sent(effects, target, module) do
    [{:send, ^target, %Envelope{payload: %{__struct__: ^module}} = envelope}] =
      Enum.filter(
        effects,
        &match?({:send, ^target, %Envelope{payload: %{__struct__: ^module}}}, &1)
      )

    envelope
  end

  defp canonical(state), do: %{state | log: Log.canonical(state.log)}
end
