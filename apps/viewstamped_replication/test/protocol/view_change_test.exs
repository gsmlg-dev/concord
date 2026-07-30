defmodule ViewstampedReplication.Protocol.ViewChangeTest do
  use ExUnit.Case, async: true

  alias ViewstampedReplication.{Configuration, Log, LogEntry, Member, Reply, Request}
  alias ViewstampedReplication.Protocol

  alias ViewstampedReplication.Protocol.{
    Commit,
    DoViewChange,
    Envelope,
    GetState,
    Prepare,
    PrepareOk,
    Recovery,
    StartView,
    StartViewChange,
    State
  }

  test "primary timeout starts the next view and a quorum completes the view change" do
    {normal, [{:persist, _}, {:schedule_timer, :primary, _, token}]} =
      Protocol.step(State.new(configuration(2)), {:storage_recovered, :bootstrap})

    assert {changing,
            [
              {:emit_telemetry, [:viewstamped_replication, :view_change, :start], _,
               %{message_type: :start_view_change}},
              {:persist, {:hard_state, %{view_number: 1, status: :view_change}}},
              {:broadcast, %Envelope{payload: %StartViewChange{view_number: 1}}},
              {:schedule_timer, :view_change, _, _}
            ]} = Protocol.step(normal, {:timeout, :primary, token})

    assert changing.status == :view_change
    assert changing.view_number == 1

    assert {quorum_state, effects} =
             peer_step(changing, 1, %StartViewChange{view_number: 1})

    assert MapSet.equal?(quorum_state.start_view_change_votes[1], MapSet.new([1, 2]))
    assert map_size(quorum_state.do_view_change_messages[1]) == 1
    assert effects == []

    remote = %DoViewChange{
      view_number: 1,
      last_normal_view: 0,
      op_number: 0,
      commit_number: 0,
      log: Log.new(),
      client_table: %{}
    }

    assert {new_primary, completion_effects} = peer_step(quorum_state, 1, remote)
    assert new_primary.status == :normal
    assert new_primary.view_number == 1
    assert new_primary.last_normal_view == 1

    assert Enum.any?(completion_effects, fn
             {:persist, {:install_state, %{view_number: 1, status: :normal}}} -> true
             _effect -> false
           end)

    assert Enum.any?(completion_effects, fn
             {:broadcast, %Envelope{payload: %StartView{view_number: 1}}} -> true
             _effect -> false
           end)

    assert Enum.any?(completion_effects, fn
             {:emit_telemetry, [:viewstamped_replication, :view_change, :stop], _,
              %{message_type: :start_view}} ->
               true

             _effect ->
               false
           end)

    assert Enum.any?(completion_effects, &match?({:schedule_timer, :heartbeat, _, _}, &1))
  end

  test "four-member view change requires three votes and three state messages" do
    {normal, [{:persist, _}, {:schedule_timer, :primary, _, token}]} =
      Protocol.step(State.new(configuration(2, 4)), {:storage_recovered, :bootstrap})

    {changing, _effects} = Protocol.step(normal, {:timeout, :primary, token})
    {two_votes, _effects} = peer_step(changing, 1, %StartViewChange{view_number: 1})

    assert two_votes.status == :view_change
    assert MapSet.equal?(two_votes.start_view_change_votes[1], MapSet.new([1, 2]))
    assert two_votes.do_view_change_messages[1] == %{}

    {quorum_state, _effects} =
      peer_step(two_votes, 3, %StartViewChange{view_number: 1})

    assert MapSet.equal?(quorum_state.start_view_change_votes[1], MapSet.new([1, 2, 3]))
    assert map_size(quorum_state.do_view_change_messages[1]) == 1

    remote = %DoViewChange{
      view_number: 1,
      last_normal_view: 0,
      op_number: 0,
      commit_number: 0,
      log: Log.new(),
      client_table: %{}
    }

    {two_messages, _effects} = peer_step(quorum_state, 1, remote)
    assert two_messages.status == :view_change
    assert map_size(two_messages.do_view_change_messages[1]) == 2

    {new_primary, _effects} = peer_step(two_messages, 3, remote)
    assert new_primary.status == :normal
    assert new_primary.view_number == 1
  end

  test "a new view durably adopts and reprepares an inherited uncommitted entry" do
    inherited = entry(1, 0, :inherited)
    inherited_log = Log.append!(Log.new(), inherited)

    backup = %{
      normal_state(3)
      | status: :view_change,
        view_number: 1,
        log: inherited_log,
        op_number: 1
    }

    start_view = %StartView{
      view_number: 1,
      op_number: 1,
      commit_number: 0,
      log: inherited_log,
      client_table: %{}
    }

    assert {installed, effects} = peer_step(backup, 2, start_view)

    persist_index =
      Enum.find_index(effects, &match?({:persist, {:install_state, %{view_number: 1}}}, &1))

    acknowledgement_index =
      Enum.find_index(
        effects,
        &match?({:send, 2, %Envelope{payload: %PrepareOk{view_number: 1, op_number: 1}}}, &1)
      )

    assert is_integer(persist_index)
    assert is_integer(acknowledgement_index)
    assert persist_index < acknowledgement_index
    assert installed.log == inherited_log
    assert Log.fetch!(installed.log, 1).view_number == 0

    heartbeat_token = {:heartbeat, 1, :adoption_retry}

    primary = %{
      normal_state(2)
      | view_number: 1,
        last_normal_view: 1,
        log: inherited_log,
        op_number: 1,
        prepare_acks: %{1 => MapSet.new([2])},
        timer_tokens: %{heartbeat: heartbeat_token}
    }

    assert {retried, retry_effects} =
             Protocol.step(primary, {:timeout, :heartbeat, heartbeat_token})

    retry =
      Enum.find_value(retry_effects, fn
        {:send, 3,
         %Envelope{
           payload: %Prepare{view_number: 1, op_number: 1, entry: ^inherited} = prepare
         }} ->
          prepare

        _effect ->
          nil
      end)

    assert %Prepare{} = retry

    assert {reacknowledged,
            [
              {:send, 2, %Envelope{payload: %PrepareOk{view_number: 1, op_number: 1}}},
              {:schedule_timer, :primary, _, _}
            ]} = peer_step(installed, 2, retry)

    assert reacknowledged.log == installed.log
    assert retried.commit_number == 0
  end

  test "equal-log view-change tie cannot regress an applied client result to pending" do
    applied_entry = entry(1, 0, :client)
    log = Log.append!(Log.new(), applied_entry)
    applied = %{request_number: 1, status: :applied, result: :result}
    pending = %{request_number: 1, status: :pending, result: nil}

    local_message = %DoViewChange{
      view_number: 1,
      last_normal_view: 0,
      op_number: 1,
      commit_number: 1,
      log: log,
      client_table: %{client: applied}
    }

    remote_message = %{
      local_message
      | commit_number: 0,
        client_table: %{client: pending}
    }

    changing = %{
      normal_state(2)
      | status: :view_change,
        view_number: 1,
        log: log,
        op_number: 1,
        commit_number: 1,
        applied_number: 1,
        client_table: %{client: applied},
        do_view_change_messages: %{1 => %{2 => local_message}}
    }

    assert {installed, _effects} = peer_step(changing, 1, remote_message)
    assert installed.status == :normal
    assert installed.applied_number == 1
    assert installed.client_table.client == applied

    request = %Request{client_id: :client, request_number: 1, operation: :client}

    assert {^installed, [{:reply, :route, %Reply{result: :result}}]} =
             Protocol.step(installed, {:client_request, :route, request})
  end

  test "a dropped targeted state transfer falls back to timed recovery" do
    stale_view_change_token = {:view_change, 1, :stale}

    changing = %{
      normal_state(3)
      | status: :view_change,
        view_number: 1,
        timer_tokens: %{view_change: stale_view_change_token}
    }

    inherited = entry(1, 0, :inherited)

    assert {recovering, effects} =
             peer_step(changing, 2, %Prepare{
               view_number: 1,
               op_number: 1,
               commit_number: 0,
               entry: inherited
             })

    assert recovering.status == :recovering
    assert {:cancel_timer, :view_change} in effects
    assert {:request_state_transfer, 2, 1..1} in effects
    assert Enum.any?(effects, &match?({:send, 2, %Envelope{payload: %GetState{}}}, &1))

    assert {:schedule_timer, :recovery, _, recovery_token} =
             Enum.find(effects, &match?({:schedule_timer, :recovery, _, _}, &1))

    assert recovering.timer_tokens.recovery == recovery_token
    refute Map.has_key?(recovering.timer_tokens, :view_change)

    assert {^recovering, []} =
             peer_step(recovering, 2, %Commit{view_number: 1, commit_number: 1})

    assert {^recovering, []} =
             Protocol.step(recovering, {:timeout, :view_change, stale_view_change_token})

    assert {retrying, retry_effects} =
             Protocol.step(recovering, {:timeout, :recovery, recovery_token})

    assert retrying.status == :recovering
    assert Enum.any?(retry_effects, &match?({:broadcast, %Envelope{payload: %Recovery{}}}, &1))
    assert Enum.any?(retry_effects, &match?({:schedule_timer, :recovery, _, _}, &1))
  end

  test "receiving a higher StartViewChange immediately joins that view" do
    state = normal_state(3)

    assert {changing, effects} =
             peer_step(state, 1, %StartViewChange{view_number: 2})

    assert changing.status == :view_change
    assert changing.view_number == 2
    assert MapSet.equal?(changing.start_view_change_votes[2], MapSet.new([1, 3]))

    assert Enum.any?(effects, fn
             {:broadcast, %Envelope{payload: %StartViewChange{view_number: 2}}} -> true
             _effect -> false
           end)

    assert %{3 => %DoViewChange{view_number: 2}} = changing.do_view_change_messages[2]
  end

  test "receiving a higher DoViewChange initiates view change but only the new primary collects it" do
    state = normal_state(2)

    message = %DoViewChange{
      view_number: 2,
      last_normal_view: 0,
      op_number: 0,
      commit_number: 0,
      log: Log.new()
    }

    assert {changing, effects} = peer_step(state, 1, message)
    assert changing.status == :view_change
    assert changing.view_number == 2
    assert changing.do_view_change_messages[2] == %{}
    assert Enum.any?(effects, &match?({:broadcast, %Envelope{payload: %StartViewChange{}}}, &1))
  end

  test "new primary selects highest last-normal-view then longest log" do
    base = normal_state(2)
    {changing, _effects} = peer_step(base, 1, %StartViewChange{view_number: 1})
    local = entry(1, 0, :local)
    remote = entry(1, 0, :remote)
    remote_second = entry(2, 0, :remote_second)

    state = %{
      changing
      | log: Log.append!(Log.new(), local),
        op_number: 1,
        start_view_change_votes: %{1 => MapSet.new([1, 2])}
    }

    # Let the prospective primary record its own current state.
    {state, _effects} = peer_step(state, 2, do_view_change(state, 0))

    longer_log = Log.new([remote, remote_second]) |> elem(1)

    remote_message = %DoViewChange{
      view_number: 1,
      last_normal_view: 1,
      op_number: 2,
      commit_number: 0,
      log: longer_log
    }

    assert {normal, _effects} = peer_step(state, 1, remote_message)
    assert normal.status == :normal
    assert normal.log == longer_log
    assert normal.op_number == 2
  end

  test "StartView installs state only from the deterministic primary and preserves commits" do
    committed_entry = entry(1, 0, :committed)

    state = %{
      normal_state(3)
      | log: Log.append!(Log.new(), committed_entry),
        op_number: 1,
        commit_number: 1
    }

    conflicting = Log.append!(Log.new(), entry(1, 1, :conflict))

    message = %StartView{
      view_number: 1,
      op_number: 1,
      commit_number: 1,
      log: conflicting
    }

    assert {^state, []} = peer_step(state, 2, message)

    safe_message = %{message | log: state.log}
    assert {installed, effects} = peer_step(state, 2, safe_message)
    assert installed.status == :normal
    assert installed.view_number == 1
    assert installed.log == state.log
    assert Enum.any?(effects, &match?({:schedule_timer, :primary, _, _}, &1))
  end

  test "view-change timeout advances repeatedly and old-view Prepare cannot mutate state" do
    {normal, [{:persist, _}, {:schedule_timer, :primary, _, primary_token}]} =
      Protocol.step(State.new(configuration(3)), {:storage_recovered, :bootstrap})

    {view_one, effects} = Protocol.step(normal, {:timeout, :primary, primary_token})
    {:schedule_timer, :view_change, _, view_token} = List.last(effects)

    {view_two, _effects} = Protocol.step(view_one, {:timeout, :view_change, view_token})
    assert view_two.view_number == 2
    assert view_two.status == :view_change

    old_prepare = %Prepare{
      view_number: 0,
      op_number: 1,
      commit_number: 0,
      entry: entry(1, 0, :old)
    }

    assert {^view_two, []} = peer_step(view_two, 1, old_prepare)
  end

  defp normal_state(replica_id), do: %{State.new(configuration(replica_id)) | status: :normal}

  defp configuration(replica_id, member_count \\ 3) do
    Configuration.new!(
      group_id: :group,
      replica_id: replica_id,
      members:
        for(
          member_id <- 1..member_count,
          do: %Member{id: member_id, endpoint: {:replica, member_id}}
        )
    )
  end

  defp entry(op_number, view_number, name) do
    %LogEntry{
      view_number: view_number,
      op_number: op_number,
      client_id: name,
      request_number: 1,
      operation: name
    }
  end

  defp do_view_change(state, last_normal_view) do
    %DoViewChange{
      view_number: state.view_number,
      last_normal_view: last_normal_view,
      op_number: state.op_number,
      commit_number: state.commit_number,
      log: state.log,
      client_table: state.client_table
    }
  end

  defp peer_step(state, sender, payload) do
    Protocol.step(
      state,
      {:peer_message, sender,
       %Envelope{
         group_id: state.group_id,
         configuration_hash: Configuration.hash(state.configuration),
         from: sender,
         payload: payload
       }}
    )
  end
end
