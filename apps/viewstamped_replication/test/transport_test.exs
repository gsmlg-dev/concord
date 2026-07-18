defmodule ViewstampedReplication.TransportTest do
  use ExUnit.Case, async: true

  alias ViewstampedReplication.Protocol.Envelope
  alias ViewstampedReplication.Transport.{Distribution, Local}

  test "local transport resolves explicit endpoint mappings through a registry" do
    registry = unique_name("registry")
    start_supervised!({Registry, keys: :unique, name: registry})
    Registry.register(registry, {:endpoint, :group, :replica_two}, nil)

    envelope = %Envelope{group_id: :group, from: 1, payload: :prepare}
    transport = Local.new(registry: registry, endpoints: %{2 => :replica_two})

    assert :ok = Local.send(transport, 2, envelope)
    assert_receive {:vsr_peer, 1, ^envelope}
  end

  test "local transport exposes delivery control to deterministic tests" do
    registry = unique_name("registry")
    test_pid = self()
    start_supervised!({Registry, keys: :unique, name: registry})
    Registry.register(registry, {:endpoint, :group, :replica_two}, nil)

    transport =
      Local.new(
        registry: registry,
        endpoints: %{2 => :replica_two},
        deliver: fn destination, message ->
          send(test_pid, {:queued, destination, message})
          :ok
        end
      )

    envelope = %Envelope{group_id: :group, from: 1, payload: :prepare}
    assert :ok = Local.send(transport, 2, envelope)
    assert_receive {:queued, destination, {:vsr_peer, 1, ^envelope}}
    assert destination == self()
    refute_receive {:vsr_peer, _, _}
  end

  test "distribution transport uses only its explicit endpoint map" do
    envelope = %Envelope{group_id: :group, from: 1, payload: :prepare}
    transport = Distribution.new(endpoints: %{2 => self()})

    assert :ok = Distribution.send(transport, 2, envelope)
    assert_receive {:vsr_peer, 1, ^envelope}
    assert {:error, {:unknown_destination, 3}} = Distribution.send(transport, 3, envelope)
  end

  test "distribution transport routes explicit node endpoints through the remote registry" do
    group_id = {:distribution_test, System.unique_integer([:positive])}

    Registry.register(
      ViewstampedReplication.Registry,
      {:replica, group_id, 2},
      nil
    )

    envelope = %Envelope{group_id: group_id, from: 1, payload: :prepare}
    transport = Distribution.new(endpoints: %{2 => node()})

    assert :ok = Distribution.send(transport, 2, envelope)
    assert_receive {:vsr_peer, 1, ^envelope}
  end

  defp unique_name(prefix) do
    :"#{prefix}_#{System.unique_integer([:positive])}"
  end
end
