defmodule ViewstampedReplication.Protocol do
  @moduledoc """
  Pure Viewstamped Replication state transition kernel.

  `step/2` contains no process, clock, storage, transport, telemetry, or state
  machine calls. It describes all of those operations as ordered effects for a
  runtime or deterministic simulator to interpret.
  """

  alias ViewstampedReplication.{Configuration, Log, LogEntry, Reply, Request}

  alias ViewstampedReplication.Protocol.{
    Commit,
    DoViewChange,
    Effect,
    Envelope,
    Event,
    GetState,
    NewState,
    Prepare,
    PrepareOk,
    Recovery,
    RecoveryResponse,
    StartView,
    StartViewChange,
    State
  }

  @protocol_version 1

  @spec step(State.t(), Event.t()) :: {State.t(), [Effect.t()]}
  def step(%State{} = state, event) do
    assert_invariants!(state)
    validate_event!(event)
    {next_state, effects} = transition(state, event)
    {assert_transition!(state, next_state), effects}
  end

  @spec assert_invariants!(State.t()) :: State.t()
  def assert_invariants!(%State{} = state) do
    assert!(state.status in [:normal, :view_change, :recovering], :invalid_status)
    assert_non_negative!(state.view_number, :view_number)
    assert_non_negative!(state.last_normal_view, :last_normal_view)
    assert_non_negative!(state.applied_number, :applied_number)
    assert_non_negative!(state.snapshot_op_number, :snapshot_op_number)
    assert_non_negative!(state.commit_number, :commit_number)
    assert_non_negative!(state.op_number, :op_number)
    assert!(state.last_normal_view <= state.view_number, :last_normal_view_ahead)

    assert!(
      state.applied_number <= state.commit_number and state.commit_number <= state.op_number,
      :invalid_operation_numbers
    )

    assert!(Log.last_op_number(state.log) == state.op_number, :log_op_number_mismatch)
    assert!(state.log.base_op_number == state.snapshot_op_number, :log_snapshot_mismatch)
    assert!(state.snapshot_op_number <= state.applied_number, :snapshot_ahead_of_applied)
    assert_applying_number!(state)
    assert_applied_requests_are_unique!(state)
    state
  end

  @spec assert_transition!(State.t(), State.t()) :: State.t()
  def assert_transition!(%State{} = previous, %State{} = current) do
    assert_invariants!(current)
    assert!(current.view_number >= previous.view_number, :view_number_decreased)
    assert!(current.commit_number >= previous.commit_number, :commit_number_decreased)
    assert!(current.applied_number >= previous.applied_number, :applied_number_decreased)
    assert_committed_prefix!(previous, current)
    current
  end

  defp transition(state, {:client_request, route, %Request{} = request}),
    do: handle_client_request(state, route, request)

  defp transition(state, {:peer_message, sender, %Envelope{} = envelope}),
    do: handle_envelope(state, sender, envelope)

  defp transition(state, {:timeout, kind, token}), do: handle_timeout(state, kind, token)

  defp transition(state, {:state_machine_applied, op_number, result}),
    do: handle_applied(state, op_number, result)

  defp transition(state, {:snapshot_completed, op_number, snapshot}),
    do: handle_snapshot_completed(state, op_number, snapshot)

  defp transition(state, {:storage_recovered, recovered}),
    do: handle_storage_recovered(state, recovered)

  defp transition(state, {:storage_failed, reason}) do
    {state,
     [
       telemetry(state, [:storage, :operation], %{result: :error, reason: reason})
     ]}
  end

  # Client request handling

  defp handle_client_request(%State{status: status} = state, route, request)
       when status != :normal do
    reply_error(state, route, request, {:error, status})
  end

  defp handle_client_request(%State{} = state, route, request) do
    if primary?(state) do
      handle_primary_request(
        state,
        route,
        request,
        Map.get(state.client_table, request.client_id)
      )
    else
      reply_error(
        state,
        route,
        request,
        {:error, {:not_primary, primary_id(state, state.view_number)}}
      )
    end
  end

  defp handle_primary_request(state, route, request, nil),
    do: append_client_request(state, route, request)

  defp handle_primary_request(state, route, request, %{request_number: recorded})
       when request.request_number < recorded,
       do: reply_error(state, route, request, {:error, :stale_request})

  defp handle_primary_request(state, route, request, %{
         request_number: recorded,
         status: :applied,
         result: result
       })
       when request.request_number == recorded do
    {state, [{:reply, route, reply(state, request, result)}]}
  end

  defp handle_primary_request(state, route, request, %{
         request_number: recorded,
         status: :pending
       })
       when request.request_number == recorded do
    pending_clients =
      Map.put(state.pending_clients, {request.client_id, request.request_number}, route)

    {%{state | pending_clients: pending_clients}, []}
  end

  defp handle_primary_request(state, route, request, %{status: :pending}),
    do: reply_error(state, route, request, {:error, :request_in_progress})

  defp handle_primary_request(state, route, request, _record),
    do: append_client_request(state, route, request)

  defp append_client_request(state, route, request) do
    op_number = state.op_number + 1

    entry = %LogEntry{
      view_number: state.view_number,
      op_number: op_number,
      client_id: request.client_id,
      request_number: request.request_number,
      operation: request.operation,
      metadata: request.metadata
    }

    log = Log.append!(state.log, entry)

    state = %{
      state
      | log: log,
        op_number: op_number,
        client_table:
          Map.put(state.client_table, request.client_id, %{
            request_number: request.request_number,
            status: :pending,
            result: nil
          }),
        pending_clients:
          Map.put(state.pending_clients, {request.client_id, request.request_number}, route),
        prepare_acks: Map.put(state.prepare_acks, op_number, MapSet.new([state.replica_id]))
    }

    prepare = %Prepare{
      view_number: state.view_number,
      op_number: op_number,
      commit_number: state.commit_number,
      entry: entry
    }

    effects = [
      telemetry(
        state,
        [:request, :start],
        %{request_number: request.request_number},
        %{message_type: :request}
      ),
      {:persist, {:append, entry}},
      {:broadcast, envelope(state, prepare)},
      telemetry(state, [:prepare, :sent], %{op_number: op_number}, %{message_type: :prepare})
    ]

    maybe_commit_prepared(state, effects)
  end

  # Peer message validation and dispatch

  defp handle_envelope(
         state,
         sender,
         %Envelope{
           protocol_version: @protocol_version,
           group_id: group_id,
           configuration_hash: configuration_hash,
           from: sender,
           payload: payload
         }
       )
       when group_id == state.group_id do
    if configuration_hash == Configuration.hash(state.configuration) and member?(state, sender),
      do: handle_message(state, sender, payload),
      else: {state, []}
  end

  defp handle_envelope(state, _sender, _envelope), do: {state, []}

  defp handle_message(state, sender, %Prepare{} = message),
    do: handle_prepare(state, sender, message)

  defp handle_message(state, sender, %PrepareOk{} = message),
    do: handle_prepare_ok(state, sender, message)

  defp handle_message(state, sender, %Commit{} = message),
    do: handle_commit(state, sender, message)

  defp handle_message(state, sender, %StartViewChange{} = message),
    do: handle_start_view_change(state, sender, message)

  defp handle_message(state, sender, %DoViewChange{} = message),
    do: handle_do_view_change(state, sender, message)

  defp handle_message(state, sender, %StartView{} = message),
    do: handle_start_view(state, sender, message)

  defp handle_message(state, sender, %Recovery{} = message),
    do: handle_recovery(state, sender, message)

  defp handle_message(state, sender, %RecoveryResponse{} = message),
    do: handle_recovery_response(state, sender, message)

  defp handle_message(state, sender, %GetState{} = message),
    do: handle_get_state(state, sender, message)

  defp handle_message(state, sender, %NewState{} = message),
    do: handle_new_state(state, sender, message)

  defp handle_message(state, _sender, _unknown), do: {state, []}

  # Normal operation

  defp handle_prepare(state, sender, %Prepare{view_number: view} = message)
       when view > state.view_number do
    if sender == primary_id(state, view),
      do: request_future_state(state, sender, message.view_number, message.op_number),
      else: {state, []}
  end

  defp handle_prepare(%State{status: :normal} = state, sender, %Prepare{
         view_number: view,
         op_number: op_number,
         commit_number: commit_number,
         entry: %LogEntry{} = entry
       })
       when view == state.view_number do
    cond do
      sender != primary_id(state, view) ->
        {state, []}

      entry.view_number != view or entry.op_number != op_number ->
        {state, []}

      op_number == state.op_number + 1 ->
        accept_prepare(state, sender, entry, commit_number)

      op_number <= state.op_number and Log.fetch(state.log, op_number) == {:ok, entry} ->
        state
        |> advance_commit(commit_number)
        |> then(fn {state, effects} ->
          {state, timer_effects} = schedule_timer(state, :primary)

          {state,
           effects ++
             [
               {:send, sender,
                envelope(
                  state,
                  %PrepareOk{view_number: view, op_number: op_number}
                )}
             ] ++ timer_effects}
        end)

      op_number > state.op_number + 1 ->
        request_missing_state(state, sender, view, state.op_number + 1, op_number)

      true ->
        {state, []}
    end
  end

  defp handle_prepare(state, _sender, _message), do: {state, []}

  defp accept_prepare(state, sender, entry, commit_number) do
    state = %{
      state
      | log: Log.append!(state.log, entry),
        op_number: entry.op_number,
        client_table: record_pending_request(state.client_table, entry)
    }

    {state, commit_effects} = advance_commit(state, commit_number)

    {state, timer_effects} = schedule_timer(state, :primary)

    effects =
      [
        {:persist, {:append, entry}}
        | commit_effects
      ] ++
        [
          {:send, sender,
           envelope(
             state,
             %PrepareOk{view_number: state.view_number, op_number: entry.op_number}
           )}
        ] ++ timer_effects

    {state, effects} = maybe_start_apply(state, effects)
    {state, effects}
  end

  defp handle_prepare_ok(%State{status: :normal} = state, sender, %PrepareOk{
         view_number: view,
         op_number: op_number
       })
       when view == state.view_number do
    cond do
      not primary?(state) ->
        {state, []}

      op_number <= state.commit_number or op_number > state.op_number ->
        {state, []}

      true ->
        # A backup only acknowledges prepares in order. Its acknowledgement for
        # N therefore also proves it has every prepare through N.
        prepare_acks =
          Enum.reduce((state.commit_number + 1)..op_number//1, state.prepare_acks, fn prepared_op,
                                                                                      acks ->
            acknowledgements =
              acks
              |> Map.get(prepared_op, MapSet.new([state.replica_id]))
              |> MapSet.put(sender)

            Map.put(acks, prepared_op, acknowledgements)
          end)

        state = %{state | prepare_acks: prepare_acks}
        maybe_commit_prepared(state, [])
    end
  end

  defp handle_prepare_ok(state, _sender, _message), do: {state, []}

  defp maybe_commit_prepared(state, effects) do
    new_commit =
      (state.commit_number + 1)..state.op_number//1
      |> Enum.reduce_while(state.commit_number, fn op_number, _committed ->
        acknowledgements = Map.get(state.prepare_acks, op_number, MapSet.new())

        if MapSet.size(acknowledgements) >= Configuration.quorum_size(state.configuration),
          do: {:cont, op_number},
          else: {:halt, op_number - 1}
      end)

    if new_commit > state.commit_number do
      state = %{state | commit_number: new_commit}

      commit_effects = [
        {:persist, {:set_commit_number, new_commit}},
        {:broadcast,
         envelope(
           state,
           %Commit{view_number: state.view_number, commit_number: new_commit}
         )},
        telemetry(state, [:commit], %{commit_number: new_commit}, %{message_type: :commit})
      ]

      maybe_start_apply(state, effects ++ commit_effects)
    else
      {state, effects}
    end
  end

  defp handle_commit(state, sender, %Commit{view_number: view, commit_number: commit_number})
       when view > state.view_number do
    if sender == primary_id(state, view),
      do: request_future_state(state, sender, view, commit_number),
      else: {state, []}
  end

  defp handle_commit(%State{status: :normal} = state, sender, %Commit{
         view_number: view,
         commit_number: commit_number
       })
       when view == state.view_number do
    cond do
      sender != primary_id(state, view) ->
        {state, []}

      commit_number > state.op_number ->
        request_missing_state(
          state,
          sender,
          view,
          state.op_number + 1,
          commit_number
        )

      true ->
        {state, effects} = advance_commit(state, commit_number)
        {state, effects} = maybe_start_apply(state, effects)
        {state, timer_effects} = schedule_timer(state, :primary)
        {state, effects ++ timer_effects}
    end
  end

  defp handle_commit(state, _sender, _message), do: {state, []}

  defp advance_commit(state, advertised_commit) do
    new_commit = min(max(advertised_commit, state.commit_number), state.op_number)

    if new_commit > state.commit_number do
      {%{state | commit_number: new_commit}, [{:persist, {:set_commit_number, new_commit}}]}
    else
      {state, []}
    end
  end

  # Application acknowledgements and client replies

  defp handle_applied(%State{applying_number: op_number} = state, op_number, result) do
    entry = Log.fetch!(state.log, op_number)

    client_table =
      Map.put(state.client_table, entry.client_id, %{
        request_number: entry.request_number,
        status: :applied,
        result: result
      })

    route_key = {entry.client_id, entry.request_number}
    route = Map.get(state.pending_clients, route_key)

    state = %{
      state
      | applied_number: op_number,
        applying_number: nil,
        client_table: client_table,
        pending_clients: Map.delete(state.pending_clients, route_key)
    }

    effects = [{:persist, {:applied, op_number, client_table}}]

    effects =
      if route && primary?(state) do
        effects ++
          [
            telemetry(
              state,
              [:request, :stop],
              %{request_number: entry.request_number},
              %{message_type: :reply}
            ),
            {:reply, route,
             %Reply{
               view_number: state.view_number,
               client_id: entry.client_id,
               request_number: entry.request_number,
               result: result
             }}
          ]
      else
        effects
      end

    maybe_start_apply(state, effects)
  end

  defp handle_applied(state, _op_number, _result), do: {state, []}

  defp handle_snapshot_completed(state, op_number, snapshot)
       when is_integer(op_number) and op_number >= state.snapshot_op_number and
              op_number <= state.applied_number do
    with {:ok, log} <- Log.compact(state.log, op_number) do
      state = %{
        state
        | log: log,
          snapshot: snapshot,
          snapshot_op_number: op_number
      }

      {state,
       [
         {:persist, {:write_snapshot, snapshot}},
         {:persist, {:install_state, install_state_operation(state)}}
       ]}
    else
      {:error, _reason} -> {state, []}
    end
  end

  defp handle_snapshot_completed(state, _op_number, _snapshot), do: {state, []}

  defp maybe_start_apply(
         %State{applying_number: nil, applied_number: applied, commit_number: commit} = state,
         effects
       )
       when applied < commit do
    op_number = applied + 1
    entry = Log.fetch!(state.log, op_number)
    {%{state | applying_number: op_number}, effects ++ [{:apply, entry}]}
  end

  defp maybe_start_apply(state, effects), do: {state, effects}

  # View changes

  defp handle_start_view_change(%State{status: :recovering} = state, _sender, _message),
    do: {state, []}

  defp handle_start_view_change(state, _sender, %StartViewChange{view_number: view})
       when view < state.view_number,
       do: {state, []}

  defp handle_start_view_change(
         %State{status: :normal, view_number: view} = state,
         _sender,
         %StartViewChange{
           view_number: view
         }
       ),
       do: {state, []}

  defp handle_start_view_change(state, sender, %StartViewChange{view_number: view}) do
    {state, effects} =
      if state.status != :view_change or view > state.view_number do
        begin_view_change(state, view)
      else
        {state, []}
      end

    votes =
      state.start_view_change_votes
      |> Map.get(view, MapSet.new([state.replica_id]))
      |> MapSet.put(sender)

    state = %{
      state
      | start_view_change_votes: Map.put(state.start_view_change_votes, view, votes)
    }

    maybe_send_do_view_change(state, effects)
  end

  defp handle_do_view_change(%State{status: :recovering} = state, _sender, _message),
    do: {state, []}

  defp handle_do_view_change(state, _sender, %DoViewChange{view_number: view})
       when view < state.view_number,
       do: {state, []}

  defp handle_do_view_change(
         %State{status: :normal, view_number: view} = state,
         _sender,
         %DoViewChange{
           view_number: view
         }
       ),
       do: {state, []}

  defp handle_do_view_change(state, sender, %DoViewChange{view_number: view} = message) do
    {state, effects} =
      if state.status != :view_change or view > state.view_number do
        begin_view_change(state, view)
      else
        {state, []}
      end

    if primary_id(state, view) == state.replica_id and valid_do_view_change?(message) do
      messages =
        state.do_view_change_messages
        |> Map.get(view, %{})
        |> Map.put(sender, message)

      state = %{
        state
        | do_view_change_messages: Map.put(state.do_view_change_messages, view, messages)
      }

      maybe_complete_view_change(state, effects)
    else
      {state, effects}
    end
  end

  defp begin_view_change(state, view) when view > state.view_number or state.status == :normal do
    last_normal_view =
      if state.status == :normal, do: state.view_number, else: state.last_normal_view

    state = %{
      state
      | status: :view_change,
        view_number: view,
        last_normal_view: last_normal_view,
        start_view_change_votes: %{view => MapSet.new([state.replica_id])},
        do_view_change_messages: %{view => %{}},
        prepare_acks: %{},
        recovery_responses: %{}
    }

    {state, timer_effects} = schedule_timer(state, :view_change)

    effects = [
      telemetry(state, [:view_change, :start], %{}, %{message_type: :start_view_change}),
      {:persist,
       {:hard_state,
        %{
          view_number: view,
          status: :view_change,
          last_normal_view: last_normal_view
        }}},
      {:broadcast, envelope(state, %StartViewChange{view_number: view})}
      | timer_effects
    ]

    maybe_send_do_view_change(state, effects)
  end

  defp begin_view_change(state, _view), do: {state, []}

  defp maybe_send_do_view_change(state, effects) do
    votes = Map.get(state.start_view_change_votes, state.view_number, MapSet.new())

    if MapSet.size(votes) >= Configuration.quorum_size(state.configuration) and
         not MapSet.member?(state.do_view_change_sent, state.view_number) do
      message = do_view_change_message(state)
      primary = primary_id(state, state.view_number)

      state = %{
        state
        | do_view_change_sent: MapSet.put(state.do_view_change_sent, state.view_number)
      }

      if primary == state.replica_id do
        messages =
          state.do_view_change_messages
          |> Map.get(state.view_number, %{})
          |> Map.put(state.replica_id, message)

        state = %{
          state
          | do_view_change_messages:
              Map.put(state.do_view_change_messages, state.view_number, messages)
        }

        maybe_complete_view_change(state, effects)
      else
        {state, effects ++ [{:send, primary, envelope(state, message)}]}
      end
    else
      {state, effects}
    end
  end

  defp maybe_complete_view_change(state, effects) do
    messages = Map.get(state.do_view_change_messages, state.view_number, %{})

    if map_size(messages) >= Configuration.quorum_size(state.configuration) do
      selected =
        messages
        |> Map.values()
        |> Enum.filter(&install_preserves_committed_prefix?(state, &1.log))
        |> Enum.max_by(&{&1.last_normal_view, &1.op_number}, fn -> nil end)

      if selected do
        safe_commit =
          messages
          |> Map.values()
          |> Enum.map(& &1.commit_number)
          |> Enum.max(fn -> state.commit_number end)
          |> min(selected.op_number)
          |> max(state.commit_number)

        install_view(
          state,
          state.view_number,
          selected.log,
          safe_commit,
          selected.client_table,
          effects,
          :primary,
          selected.snapshot,
          selected.snapshot_op_number,
          selected.log_suffix
        )
      else
        {state, effects}
      end
    else
      {state, effects}
    end
  end

  defp install_view(
         state,
         view,
         log,
         commit_number,
         client_table,
         effects,
         role,
         snapshot,
         snapshot_op_number,
         log_suffix
       ) do
    previous_status = state.status
    op_number = Log.last_op_number(log)
    client_table = normalize_client_table(log, client_table)
    snapshot_op_number = normalized_snapshot_op_number(snapshot, snapshot_op_number)
    applied_number = if snapshot, do: snapshot_op_number, else: state.applied_number

    state = %{
      state
      | status: :normal,
        view_number: view,
        last_normal_view: view,
        op_number: op_number,
        commit_number: max(state.commit_number, min(commit_number, op_number)),
        log: log,
        client_table: client_table,
        applied_number: applied_number,
        applying_number:
          if(state.applying_number && state.applying_number <= applied_number,
            do: nil,
            else: state.applying_number
          ),
        snapshot: snapshot || state.snapshot,
        snapshot_op_number: if(snapshot, do: snapshot_op_number, else: state.snapshot_op_number),
        prepare_acks: %{},
        start_view_change_votes: %{},
        do_view_change_messages: %{},
        recovery_nonce: nil,
        recovery_responses: %{}
    }

    install = install_state_operation(state)

    snapshot_effects =
      if snapshot, do: [{:persist, {:install_snapshot, snapshot}}], else: []

    effects =
      effects ++
        snapshot_effects ++
        [
          {:persist, {:install_state, install}},
          {:cancel_timer, :view_change},
          {:cancel_timer, :recovery}
        ]

    effects =
      case previous_status do
        :view_change ->
          effects ++
            [
              telemetry(state, [:view_change, :stop], %{}, %{message_type: :start_view})
            ]

        :recovering ->
          effects ++
            [telemetry(state, [:recovery, :stop], %{}, %{message_type: :new_state})]

        :normal ->
          effects
      end

    effects =
      if role == :primary do
        effects ++
          [
            {:broadcast,
             envelope(
               state,
               %StartView{
                 view_number: view,
                 op_number: op_number,
                 commit_number: state.commit_number,
                 log: log,
                 client_table: client_table,
                 snapshot: state.snapshot,
                 snapshot_op_number: state.snapshot_op_number,
                 log_suffix: log_suffix
               }
             )}
          ]
      else
        effects
      end

    {state, effects} = schedule_normal_timer(state, effects)
    maybe_start_apply(state, effects)
  end

  defp handle_start_view(state, _sender, %StartView{view_number: view})
       when view < state.view_number,
       do: {state, []}

  defp handle_start_view(state, sender, %StartView{
         view_number: view,
         op_number: op_number,
         commit_number: commit_number,
         log: %Log{} = log,
         client_table: client_table,
         snapshot: snapshot,
         snapshot_op_number: snapshot_op_number,
         log_suffix: log_suffix
       }) do
    {log, snapshot, snapshot_op_number, log_suffix} =
      prepare_snapshot_install(state, snapshot, snapshot_op_number, log_suffix, log)

    cond do
      sender != primary_id(state, view) ->
        {state, []}

      Log.last_op_number(log) != op_number ->
        {state, []}

      not install_preserves_committed_prefix?(state, log) ->
        {state, []}

      not valid_snapshot_transfer?(
        state,
        snapshot,
        snapshot_op_number,
        log_suffix,
        log,
        commit_number
      ) ->
        {state, []}

      true ->
        install_view(
          state,
          view,
          log,
          commit_number,
          client_table || %{},
          [],
          :backup,
          snapshot,
          snapshot_op_number,
          log_suffix
        )
    end
  end

  defp handle_start_view(state, _sender, _message), do: {state, []}

  # Recovery and state transfer

  defp handle_recovery(%State{status: :normal} = state, sender, %Recovery{nonce: nonce}) do
    response =
      if primary?(state) do
        %RecoveryResponse{
          nonce: nonce,
          view_number: state.view_number,
          status: :normal,
          op_number: state.op_number,
          commit_number: state.commit_number,
          log: state.log,
          client_table: state.client_table,
          snapshot: state.snapshot,
          snapshot_op_number: state.snapshot_op_number,
          log_suffix: Log.to_list(state.log)
        }
      else
        %RecoveryResponse{
          nonce: nonce,
          view_number: state.view_number,
          status: :normal,
          op_number: nil,
          commit_number: nil,
          log: nil,
          client_table: nil
        }
      end

    {state, [{:send, sender, envelope(state, response)}]}
  end

  defp handle_recovery(state, _sender, _message), do: {state, []}

  defp handle_recovery_response(
         %State{status: :recovering, recovery_nonce: nonce} = state,
         sender,
         %RecoveryResponse{nonce: nonce, status: :normal} = response
       ) do
    responses = Map.put(state.recovery_responses, sender, response)
    state = %{state | recovery_responses: responses}
    maybe_finish_recovery(state)
  end

  defp handle_recovery_response(state, _sender, _message), do: {state, []}

  defp maybe_finish_recovery(state) do
    if map_size(state.recovery_responses) >= Configuration.quorum_size(state.configuration) do
      highest_view =
        state.recovery_responses
        |> Map.values()
        |> Enum.map(& &1.view_number)
        |> Enum.max()

      expected_primary = primary_id(state, highest_view)
      primary_response = Map.get(state.recovery_responses, expected_primary)

      if full_recovery_response?(primary_response, highest_view) and
           valid_checkpoint_payload?(
             primary_response.snapshot,
             primary_response.snapshot_op_number,
             primary_response.log_suffix,
             primary_response.log
           ) and
           install_preserves_committed_prefix?(state, primary_response.log) do
        install_view(
          state,
          highest_view,
          primary_response.log,
          primary_response.commit_number,
          primary_response.client_table || %{},
          [],
          if(expected_primary == state.replica_id, do: :primary, else: :backup),
          primary_response.snapshot,
          primary_response.snapshot_op_number,
          primary_response.log_suffix
        )
      else
        {state, []}
      end
    else
      {state, []}
    end
  end

  defp full_recovery_response?(
         %RecoveryResponse{
           view_number: view,
           op_number: op_number,
           commit_number: commit_number,
           log: %Log{} = log
         },
         view
       )
       when is_integer(op_number) and is_integer(commit_number),
       do:
         Log.last_op_number(log) == op_number and commit_number <= op_number and
           log.base_op_number <= commit_number

  defp full_recovery_response?(_response, _view), do: false

  defp handle_get_state(%State{status: :normal} = state, sender, %GetState{
         view_number: view,
         from_op_number: from_op_number
       })
       when view == state.view_number and is_integer(from_op_number) and from_op_number > 0 do
    if primary?(state) do
      message = state_transfer_message(state, from_op_number)

      {state, [{:send, sender, envelope(state, message)}]}
    else
      {state, []}
    end
  end

  defp handle_get_state(state, _sender, _message), do: {state, []}

  defp handle_new_state(state, sender, %NewState{
         view_number: view,
         op_number: op_number,
         commit_number: commit_number,
         log: %Log{} = log,
         client_table: client_table,
         snapshot: snapshot,
         snapshot_op_number: snapshot_op_number,
         log_suffix: log_suffix
       }) do
    {log, snapshot, snapshot_op_number, log_suffix} =
      prepare_snapshot_install(state, snapshot, snapshot_op_number, log_suffix, log)

    with true <- view >= state.view_number,
         true <- sender == primary_id(state, view),
         {:ok, merged_log} <- merge_transferred_log(state, snapshot, log),
         true <- Log.last_op_number(merged_log) == op_number,
         true <- install_preserves_committed_prefix?(state, merged_log),
         true <-
           valid_snapshot_transfer?(
             state,
             snapshot,
             snapshot_op_number,
             log_suffix,
             merged_log,
             commit_number
           ) do
      install_view(
        state,
        view,
        merged_log,
        commit_number,
        client_table || %{},
        [],
        :backup,
        snapshot,
        snapshot_op_number,
        Log.to_list(merged_log)
      )
    else
      _invalid -> {state, []}
    end
  end

  defp handle_new_state(state, _sender, _message), do: {state, []}

  defp request_future_state(state, sender, view, advertised_op) do
    state = %{
      state
      | status: :recovering,
        view_number: view,
        prepare_acks: %{},
        start_view_change_votes: %{},
        do_view_change_messages: %{}
    }

    range = (state.op_number + 1)..max(state.op_number + 1, advertised_op)//1

    effects = [
      {:persist,
       {:hard_state,
        %{
          view_number: view,
          status: :recovering,
          last_normal_view: state.last_normal_view
        }}},
      {:request_state_transfer, sender, range},
      {:send, sender,
       envelope(
         state,
         %GetState{view_number: view, from_op_number: state.op_number + 1}
       )}
    ]

    {state, effects}
  end

  defp request_missing_state(state, sender, view, from_op, through_op) do
    {state,
     [
       {:request_state_transfer, sender, from_op..through_op},
       {:send, sender, envelope(state, %GetState{view_number: view, from_op_number: from_op})}
     ]}
  end

  # Storage bootstrap

  defp handle_storage_recovered(state, :empty), do: bootstrap_empty(state, recovery_nonce(state))
  defp handle_storage_recovered(state, {:empty, nonce}), do: bootstrap_empty(state, nonce)
  defp handle_storage_recovered(state, :bootstrap), do: bootstrap_fresh_cluster(state)
  defp handle_storage_recovered(state, {:bootstrap, _nonce}), do: bootstrap_fresh_cluster(state)

  defp handle_storage_recovered(state, {:durable, recovered}) when is_map(recovered),
    do: handle_storage_recovered(state, Map.put(recovered, :locally_durable, true))

  defp handle_storage_recovered(state, recovered) when is_map(recovered) do
    with :ok <- validate_recovered_identity(state, recovered),
         {:ok, log} <- recovered_log(recovered) do
      hard_state = Map.get(recovered, :hard_state, %{})
      view = Map.get(hard_state, :view_number, Map.get(recovered, :view_number, 0))
      last_normal_view = Map.get(hard_state, :last_normal_view, min(view, state.last_normal_view))
      commit_number = Map.get(recovered, :commit_number, 0)
      applied_number = Map.get(recovered, :applied_number, 0)
      client_table = Map.get(recovered, :client_table, %{})
      snapshot = Map.get(recovered, :snapshot)
      snapshot_op_number = normalized_snapshot_op_number(snapshot, 0)

      recovered_status =
        Map.get(hard_state, :status, Map.get(recovered, :status, :recovering))

      if valid_recovered_numbers?(
           view,
           last_normal_view,
           commit_number,
           applied_number,
           snapshot_op_number,
           log
         ) do
        state = %{
          state
          | view_number: view,
            last_normal_view: last_normal_view,
            op_number: Log.last_op_number(log),
            commit_number: commit_number,
            applied_number: applied_number,
            log: log,
            client_table: normalize_client_table(log, client_table),
            snapshot: snapshot,
            snapshot_op_number: snapshot_op_number
        }

        cond do
          Configuration.member_count(state.configuration) == 1 ->
            enter_singleton_normal(state)

          Map.get(recovered, :locally_durable, false) ->
            enter_durable_recovered(state, recovered_status)

          true ->
            bootstrap_recovery(state, Map.get(recovered, :recovery_nonce, recovery_nonce(state)))
        end
      else
        {state, []}
      end
    else
      _error -> {state, []}
    end
  end

  defp handle_storage_recovered(state, _invalid), do: {state, []}

  defp bootstrap_empty(state, nonce) do
    if Configuration.member_count(state.configuration) == 1 do
      enter_singleton_normal(state)
    else
      bootstrap_recovery(state, nonce)
    end
  end

  defp bootstrap_fresh_cluster(state) do
    state = %{
      state
      | status: :normal,
        last_normal_view: state.view_number,
        recovery_nonce: nil,
        recovery_responses: %{}
    }

    effects = [
      {:persist,
       {:hard_state,
        %{
          view_number: state.view_number,
          status: :normal,
          last_normal_view: state.view_number
        }}}
    ]

    schedule_normal_timer(state, effects)
  end

  defp enter_singleton_normal(state) do
    state = %{state | status: :normal, last_normal_view: state.view_number}

    effects = [
      {:persist,
       {:hard_state,
        %{
          view_number: state.view_number,
          status: :normal,
          last_normal_view: state.view_number
        }}}
    ]

    {state, effects} = schedule_normal_timer(state, effects)
    maybe_start_apply(state, effects)
  end

  defp enter_durable_recovered(state, :normal) do
    state = %{state | status: :normal}
    {state, effects} = schedule_normal_timer(state, [])
    maybe_start_apply(state, effects)
  end

  defp enter_durable_recovered(state, :view_change) do
    state = %{
      state
      | status: :view_change,
        start_view_change_votes: %{state.view_number => MapSet.new([state.replica_id])}
    }

    {state, timer_effects} = schedule_timer(state, :view_change)

    {state,
     [
       {:broadcast, envelope(state, %StartViewChange{view_number: state.view_number})}
       | timer_effects
     ]}
  end

  defp enter_durable_recovered(state, _status),
    do: bootstrap_recovery(state, recovery_nonce(state))

  defp bootstrap_recovery(state, nonce) do
    state = %{
      state
      | status: :recovering,
        recovery_nonce: nonce,
        recovery_attempt: state.recovery_attempt + 1,
        recovery_responses: %{}
    }

    {state, timer_effects} = schedule_timer(state, :recovery)

    {state,
     [
       {:broadcast, envelope(state, %Recovery{nonce: nonce})},
       telemetry(state, [:recovery, :start], %{}, %{message_type: :recovery})
       | timer_effects
     ]}
  end

  defp validate_recovered_identity(state, recovered) do
    cond do
      Map.has_key?(recovered, :configuration_hash) and
          recovered.configuration_hash != Configuration.hash(state.configuration) ->
        {:error, :configuration_mismatch}

      Map.has_key?(recovered, :replica_id) and recovered.replica_id != state.replica_id ->
        {:error, :replica_mismatch}

      true ->
        :ok
    end
  end

  defp recovered_log(recovered) do
    snapshot_op_number =
      recovered
      |> Map.get(:snapshot)
      |> normalized_snapshot_op_number(0)

    case Map.get(recovered, :log, Log.new()) do
      %Log{} = log ->
        align_log_to_snapshot(log, snapshot_op_number)

      entries when is_list(entries) ->
        case Log.new(entries) do
          {:ok, log} -> align_log_to_snapshot(log, snapshot_op_number)
          {:error, _reason} -> Log.new(snapshot_op_number, entries)
        end

      _other ->
        {:error, :invalid_log}
    end
  end

  defp align_log_to_snapshot(%Log{base_op_number: snapshot_op_number} = log, snapshot_op_number),
    do: {:ok, log}

  defp align_log_to_snapshot(%Log{} = log, snapshot_op_number),
    do: Log.compact(log, snapshot_op_number)

  # Timers

  defp handle_timeout(%State{status: :normal} = state, :primary, token) do
    if timer_current?(state, :primary, token) and not primary?(state),
      do: begin_view_change(state, state.view_number + 1),
      else: {state, []}
  end

  defp handle_timeout(%State{status: :normal} = state, :heartbeat, token) do
    if timer_current?(state, :heartbeat, token) and primary?(state) do
      effects = [
        {:broadcast,
         envelope(
           state,
           %Commit{view_number: state.view_number, commit_number: state.commit_number}
         )}
      ]

      schedule_normal_timer(state, effects)
    else
      {state, []}
    end
  end

  defp handle_timeout(%State{status: :view_change} = state, :view_change, token) do
    if timer_current?(state, :view_change, token),
      do: begin_view_change(state, state.view_number + 1),
      else: {state, []}
  end

  defp handle_timeout(%State{status: :recovering} = state, :recovery, token) do
    if timer_current?(state, :recovery, token) do
      bootstrap_recovery(state, recovery_nonce(state))
    else
      {state, []}
    end
  end

  defp handle_timeout(state, _kind, _token), do: {state, []}

  defp schedule_normal_timer(state, effects) do
    kind = if primary?(state), do: :heartbeat, else: :primary
    {state, timer_effects} = schedule_timer(state, kind)
    {state, effects ++ timer_effects}
  end

  defp schedule_timer(state, kind) do
    sequence = state.timer_sequence + 1
    token = {kind, state.view_number, sequence}

    state = %{
      state
      | timer_sequence: sequence,
        timer_tokens: Map.put(state.timer_tokens, kind, token)
    }

    {state, [{:schedule_timer, kind, Map.fetch!(state.timeouts, kind), token}]}
  end

  defp timer_current?(state, kind, token), do: Map.get(state.timer_tokens, kind) == token

  # Shared helpers

  defp do_view_change_message(state) do
    %DoViewChange{
      view_number: state.view_number,
      last_normal_view: state.last_normal_view,
      op_number: state.op_number,
      commit_number: state.commit_number,
      log: state.log,
      client_table: state.client_table,
      snapshot: state.snapshot,
      snapshot_op_number: state.snapshot_op_number,
      log_suffix: Log.to_list(state.log)
    }
  end

  defp valid_do_view_change?(%DoViewChange{
         op_number: op_number,
         commit_number: commit_number,
         log: %Log{} = log,
         snapshot: snapshot,
         snapshot_op_number: snapshot_op_number,
         log_suffix: log_suffix
       })
       when is_integer(op_number) and is_integer(commit_number),
       do:
         Log.last_op_number(log) == op_number and commit_number <= op_number and
           valid_checkpoint_payload?(snapshot, snapshot_op_number, log_suffix, log)

  defp valid_do_view_change?(_message), do: false

  defp install_preserves_committed_prefix?(state, %Log{} = log) do
    Log.last_op_number(log) >= state.commit_number and
      Enum.all?(1..state.commit_number//1, fn op_number ->
        case {Log.fetch(state.log, op_number), Log.fetch(log, op_number)} do
          {{:ok, entry}, {:ok, entry}} -> true
          {_local, :compacted} -> true
          {:compacted, _remote} -> true
          _mismatch -> false
        end
      end)
  end

  defp install_preserves_committed_prefix?(_state, _log), do: false

  defp record_pending_request(client_table, entry) do
    case Map.get(client_table, entry.client_id) do
      %{request_number: request_number} when request_number >= entry.request_number ->
        client_table

      _record ->
        Map.put(client_table, entry.client_id, %{
          request_number: entry.request_number,
          status: :pending,
          result: nil
        })
    end
  end

  defp normalize_client_table(log, client_table) do
    Enum.reduce(Log.to_list(log), client_table || %{}, fn entry, table ->
      record_pending_request(table, entry)
    end)
  end

  defp state_transfer_message(state, from_op_number)
       when from_op_number > state.log.base_op_number do
    suffix = Log.suffix(state.log, from_op_number - 1)
    {:ok, suffix_log} = Log.new(from_op_number - 1, suffix)

    %NewState{
      view_number: state.view_number,
      last_normal_view: state.last_normal_view,
      op_number: state.op_number,
      commit_number: state.commit_number,
      log: suffix_log,
      client_table: state.client_table,
      snapshot: nil,
      snapshot_op_number: 0,
      log_suffix: suffix
    }
  end

  defp state_transfer_message(state, _from_op_number) do
    %NewState{
      view_number: state.view_number,
      last_normal_view: state.last_normal_view,
      op_number: state.op_number,
      commit_number: state.commit_number,
      log: state.log,
      client_table: state.client_table,
      snapshot: state.snapshot,
      snapshot_op_number: state.snapshot_op_number,
      log_suffix: Log.to_list(state.log)
    }
  end

  defp merge_transferred_log(_state, snapshot, %Log{} = log) when not is_nil(snapshot),
    do: {:ok, log}

  defp merge_transferred_log(
         %State{log: local_log},
         nil,
         %Log{base_op_number: transfer_base, entries: suffix}
       )
       when transfer_base == local_log.base_op_number,
       do: Log.new(local_log.base_op_number, suffix)

  defp merge_transferred_log(
         %State{log: local_log, op_number: local_op},
         nil,
         %Log{base_op_number: transfer_base, entries: suffix}
       )
       when transfer_base > local_log.base_op_number and transfer_base <= local_op do
    prefix_length = transfer_base - local_log.base_op_number
    prefix = Enum.take(Log.to_list(local_log), prefix_length)
    Log.new(local_log.base_op_number, prefix ++ suffix)
  end

  defp merge_transferred_log(_state, _snapshot, _log), do: {:error, :invalid_state_transfer}

  defp prepare_snapshot_install(_state, nil, snapshot_op_number, suffix, log),
    do: {log, nil, snapshot_op_number, suffix}

  defp prepare_snapshot_install(state, snapshot, snapshot_op_number, suffix, log) do
    normalized = normalized_snapshot_op_number(snapshot, snapshot_op_number)

    if normalized < state.applied_number do
      case retain_local_applied_prefix(state.log, log) do
        {:ok, retained_log} -> {retained_log, nil, 0, Log.to_list(retained_log)}
        {:error, _reason} -> {log, snapshot, snapshot_op_number, suffix}
      end
    else
      {log, snapshot, snapshot_op_number, suffix}
    end
  end

  defp retain_local_applied_prefix(
         %Log{base_op_number: base} = _local,
         %Log{base_op_number: base} = incoming
       ),
       do: {:ok, incoming}

  defp retain_local_applied_prefix(
         %Log{base_op_number: local_base} = local,
         %Log{base_op_number: incoming_base, entries: suffix}
       )
       when incoming_base > local_base do
    if incoming_base <= Log.last_op_number(local) do
      prefix_length = incoming_base - local_base
      prefix = Enum.take(Log.to_list(local), prefix_length)
      Log.new(local_base, prefix ++ suffix)
    else
      {:error, :missing_local_prefix}
    end
  end

  defp retain_local_applied_prefix(
         %Log{base_op_number: local_base},
         %Log{base_op_number: incoming_base} = incoming
       )
       when incoming_base < local_base,
       do: Log.compact(incoming, local_base)

  defp retain_local_applied_prefix(_local, _incoming),
    do: {:error, :cannot_retain_local_applied_prefix}

  defp valid_snapshot_transfer?(
         state,
         nil,
         _snapshot_op_number,
         _suffix,
         %Log{base_op_number: base},
         _commit
       ),
       do: base == state.snapshot_op_number

  defp valid_snapshot_transfer?(
         state,
         snapshot,
         snapshot_op_number,
         suffix,
         %Log{base_op_number: base} = log,
         commit_number
       )
       when not is_nil(snapshot) and is_list(suffix) do
    normalized = normalized_snapshot_op_number(snapshot, snapshot_op_number)

    normalized == base and
      normalized >= state.applied_number and
      normalized <= commit_number and
      suffix == Log.to_list(log)
  end

  defp valid_snapshot_transfer?(
         _state,
         _snapshot,
         _snapshot_op_number,
         _suffix,
         _log,
         _commit
       ),
       do: false

  defp normalized_snapshot_op_number(nil, _advertised), do: 0

  defp normalized_snapshot_op_number(snapshot, advertised) do
    case snapshot do
      %{last_op_number: last_op_number}
      when is_integer(last_op_number) and last_op_number >= 0 ->
        last_op_number

      _snapshot when is_integer(advertised) and advertised >= 0 ->
        advertised

      _snapshot ->
        0
    end
  end

  defp valid_checkpoint_payload?(nil, _snapshot_op_number, _suffix, %Log{base_op_number: 0}),
    do: true

  defp valid_checkpoint_payload?(
         snapshot,
         snapshot_op_number,
         suffix,
         %Log{base_op_number: base} = log
       )
       when not is_nil(snapshot) and is_list(suffix) do
    normalized_snapshot_op_number(snapshot, snapshot_op_number) == base and
      suffix == Log.to_list(log)
  end

  defp valid_checkpoint_payload?(_snapshot, _snapshot_op_number, _suffix, _log), do: false

  defp valid_recovered_numbers?(
         view,
         last_normal_view,
         commit_number,
         applied_number,
         snapshot_op_number,
         log
       ) do
    Enum.all?(
      [view, last_normal_view, commit_number, applied_number, snapshot_op_number],
      &(is_integer(&1) and &1 >= 0)
    ) and
      last_normal_view <= view and
      snapshot_op_number == log.base_op_number and
      snapshot_op_number <= applied_number and
      applied_number <= commit_number and
      commit_number <= Log.last_op_number(log)
  end

  defp install_state_operation(state) do
    %{
      view_number: state.view_number,
      last_normal_view: state.last_normal_view,
      status: state.status,
      log: state.log,
      op_number: state.op_number,
      commit_number: state.commit_number,
      applied_number: state.applied_number,
      client_table: state.client_table,
      snapshot: state.snapshot,
      snapshot_op_number: state.snapshot_op_number
    }
  end

  defp recovery_nonce(state),
    do: {state.replica_id, state.view_number, state.recovery_attempt + 1}

  defp envelope(state, payload) do
    %Envelope{
      protocol_version: @protocol_version,
      group_id: state.group_id,
      configuration_hash: Configuration.hash(state.configuration),
      from: state.replica_id,
      payload: payload
    }
  end

  defp primary?(state), do: primary_id(state, state.view_number) == state.replica_id
  defp primary_id(state, view), do: Configuration.primary_id(state.configuration, view)

  defp member?(state, replica_id),
    do: Enum.any?(state.configuration.members, &(&1.id == replica_id))

  defp reply_error(state, route, request, result) do
    error_reply = %{reply(state, request, result) | status: :error}
    {state, [{:reply, route, error_reply}]}
  end

  defp reply(state, request, result) do
    %Reply{
      view_number: state.view_number,
      client_id: request.client_id,
      request_number: request.request_number,
      result: result
    }
  end

  defp telemetry(state, suffix, measurements) do
    telemetry(state, suffix, measurements, %{})
  end

  defp telemetry(state, suffix, measurements, extra_metadata) do
    {:emit_telemetry, [:viewstamped_replication | suffix], measurements,
     telemetry_metadata(state, extra_metadata)}
  end

  defp telemetry_metadata(state, extra) do
    Map.merge(
      %{
        group_id: state.group_id,
        replica_id: state.replica_id,
        view_number: state.view_number,
        op_number: state.op_number,
        commit_number: state.commit_number,
        primary_id: primary_id(state, state.view_number)
      },
      extra
    )
  end

  defp assert_committed_prefix!(previous, current) do
    Enum.each(1..previous.commit_number//1, fn op_number ->
      assert!(
        committed_position_preserved?(previous.log, current.log, op_number),
        {:committed_entry_replaced, op_number}
      )
    end)
  end

  defp committed_position_preserved?(previous, current, op_number) do
    case {Log.fetch(previous, op_number), Log.fetch(current, op_number)} do
      {{:ok, entry}, {:ok, entry}} -> true
      {_previous, :compacted} -> true
      {:compacted, _current} -> true
      _mismatch -> false
    end
  end

  defp assert_applying_number!(%State{applying_number: nil}), do: :ok

  defp assert_applying_number!(state) do
    assert!(
      state.applying_number == state.applied_number + 1 and
        state.applying_number <= state.commit_number,
      :invalid_applying_number
    )
  end

  defp assert_applied_requests_are_unique!(state) do
    applied_requests =
      state.log
      |> Log.to_list()
      |> Enum.take(state.applied_number)
      |> Enum.map(&{&1.client_id, &1.request_number})

    assert!(
      MapSet.size(MapSet.new(applied_requests)) == length(applied_requests),
      :client_request_applied_more_than_once
    )
  end

  defp validate_event!({:client_request, _route, %Request{}}), do: :ok
  defp validate_event!({:peer_message, _replica_id, %Envelope{}}), do: :ok
  defp validate_event!({:timeout, timer_kind, _token}) when is_atom(timer_kind), do: :ok

  defp validate_event!({:state_machine_applied, op_number, _result})
       when is_integer(op_number) and op_number >= 0,
       do: :ok

  defp validate_event!({:snapshot_completed, op_number, _snapshot})
       when is_integer(op_number) and op_number >= 0,
       do: :ok

  defp validate_event!({:storage_recovered, _recovered_state}), do: :ok
  defp validate_event!({:storage_failed, _reason}), do: :ok

  defp validate_event!(event),
    do: raise(ArgumentError, "invalid protocol event: #{inspect(event)}")

  defp assert_non_negative!(value, _field) when is_integer(value) and value >= 0, do: :ok

  defp assert_non_negative!(_value, field),
    do: raise(ArgumentError, "protocol invariant violated: #{field}")

  defp assert!(true, _reason), do: :ok

  defp assert!(false, reason),
    do: raise(ArgumentError, "protocol invariant violated: #{inspect(reason)}")
end
