defmodule ViewstampedReplication.Protocol.ViewChangeTest do
  use ExUnit.Case, async: true

  alias ViewstampedReplication.{Configuration, Log, LogEntry, Member}
  alias ViewstampedReplication.Protocol

  alias ViewstampedReplication.Protocol.{
    DoViewChange,
    Envelope,
    Prepare,
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

  defp configuration(replica_id) do
    Configuration.new!(
      group_id: :group,
      replica_id: replica_id,
      members: [
        %Member{id: 1, endpoint: :one},
        %Member{id: 2, endpoint: :two},
        %Member{id: 3, endpoint: :three}
      ]
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
