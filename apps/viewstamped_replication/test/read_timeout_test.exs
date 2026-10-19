defmodule ViewstampedReplication.ReadTimeoutTest do
  use ExUnit.Case, async: true

  alias ViewstampedReplication.{Member, Replica}

  defmodule MockReplica do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      Registry.register(
        ViewstampedReplication.Registry,
        {:replica, opts[:group_id], opts[:id]},
        nil
      )

      {:ok, Map.new(opts)}
    end

    @impl true
    def handle_call(:primary, from, state) do
      reply_after(from, {:ok, state.id}, state.primary_delay)
      {:noreply, state}
    end

    def handle_call({:linearizable_read, _operation}, from, state) do
      send(state.owner, {:read_started, state.id})
      reply_after(from, state.result, state.read_delay)
      {:noreply, state}
    end

    @impl true
    def handle_info({:reply, from, result}, state) do
      GenServer.reply(from, result)
      {:noreply, state}
    end

    defp reply_after(_from, _result, :infinity), do: :ok

    defp reply_after(from, result, delay),
      do: Process.send_after(self(), {:reply, from, result}, delay)
  end

  setup do
    {:ok, group: {__MODULE__, System.unique_integer([:positive, :monotonic])}}
  end

  test "primary discovery uses the requested read timeout and returns an error", %{group: group} do
    member = start_mock(group, 1, primary_delay: :infinity)
    started = System.monotonic_time(:millisecond)

    assert {:error, :timeout} =
             ViewstampedReplication.read(group, :probe,
               replica_id: 1,
               replicas: [member],
               timeout: 50
             )

    assert System.monotonic_time(:millisecond) - started < 1_000
    refute_received {:read_started, 1}
  end

  test "discovery and guarded read share one timeout budget", %{group: group} do
    member = start_mock(group, 1, primary_delay: 150, read_delay: 150)

    assert {:error, :quorum_unavailable} =
             ViewstampedReplication.read(group, :probe,
               replica_id: 1,
               replicas: [member],
               timeout: 200
             )

    assert_received {:read_started, 1}
  end

  test "redirected read uses the original deadline", %{group: group} do
    first =
      start_mock(group, 1,
        primary_delay: 80,
        read_delay: 80,
        result: {:error, {:not_primary, 2}}
      )

    second = start_mock(group, 2, read_delay: 80)

    assert {:error, :quorum_unavailable} =
             ViewstampedReplication.read(group, :probe,
               replica_id: 1,
               replicas: [first, second],
               timeout: 200
             )

    assert_received {:read_started, 1}
    assert_received {:read_started, 2}
  end

  test "infinite timeout supports local and RPC read endpoints", %{group: group} do
    member = start_mock(group, 1, primary_delay: 10, read_delay: 10)

    for endpoint <- [node(), {:replica, node()}] do
      assert {:ok, :confirmed} =
               ViewstampedReplication.read(group, :probe,
                 replica_id: 1,
                 replicas: [%{member | endpoint: endpoint}],
                 timeout: :infinity
               )
    end
  end

  test "RPC guarded reads honor their remaining timeout", %{group: group} do
    member = start_mock(group, 1, read_delay: :infinity)

    assert {:error, :quorum_unavailable} =
             ViewstampedReplication.read(group, :probe,
               replica_id: 1,
               replicas: [%{member | endpoint: {:replica, node()}}],
               timeout: 50
             )
  end

  test "missing replicas remain structured errors with finite and infinite timeouts", %{
    group: group
  } do
    member = %Member{id: 1, endpoint: node()}

    for timeout <- [50, :infinity] do
      assert {:error, :not_found} =
               ViewstampedReplication.read(group, :probe,
                 replica_id: 1,
                 replicas: [member],
                 timeout: timeout
               )
    end

    assert {:error, :not_found} = ViewstampedReplication.primary(group, 1)
  end

  test "primary API preserves its default timeout without leaking exits", %{group: group} do
    start_mock(group, 1, primary_delay: :infinity)
    assert {:error, :timeout} = Replica.primary(group, 1, timeout: 20)
    assert {:error, :timeout} = ViewstampedReplication.primary(group, 1)
  end

  defp start_mock(group, id, opts) do
    opts =
      Keyword.merge(
        [
          group_id: group,
          id: id,
          owner: self(),
          primary_delay: 0,
          read_delay: 0,
          result: {:ok, :confirmed}
        ],
        opts
      )

    start_supervised!(Supervisor.child_spec({MockReplica, opts}, id: id))
    %Member{id: id, endpoint: node()}
  end
end
