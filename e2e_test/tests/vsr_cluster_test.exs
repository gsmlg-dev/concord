defmodule Concord.E2E.VSRClusterTest do
  use ExUnit.Case, async: false

  alias Concord.E2E.Cluster

  @moduletag :e2e
  @timeout 20_000

  test "three release nodes preserve strong reads across primary failover" do
    nodes = Cluster.nodes()

    assert Enum.all?(nodes, &(Node.ping(&1) == :pong))
    assert_all(nodes, Concord.Engine, :engine, [[]], Concord.Engine.VSR)

    assert {:ok, primary} = wait_for_primary(nodes)
    key_before = unique_key("before-failover")

    assert :ok = :rpc.call(List.last(nodes), Concord, :put, [key_before, "committed"])
    assert_strong_value(nodes, key_before, "committed")

    :erpc.cast(primary, System, :stop, [0])
    assert :ok = wait_until(fn -> Node.ping(primary) == :pang end)

    remaining = nodes -- [primary]
    assert {:ok, new_primary} = wait_for_primary(remaining)
    refute new_primary == primary

    key_after = unique_key("after-failover")

    assert :ok =
             eventually(fn ->
               :rpc.call(List.last(remaining), Concord, :put, [key_after, "still-available"])
             end)

    assert_strong_value(remaining, key_before, "committed")
    assert_strong_value(remaining, key_after, "still-available")
  end

  defp wait_for_primary(nodes) do
    case eventually(fn -> current_primary(nodes) end) do
      {:ok, primary} -> {:ok, primary}
      {:error, :timeout} -> {:error, :primary_timeout}
    end
  end

  defp current_primary(nodes) do
    results =
      Enum.map(nodes, fn node ->
        :rpc.call(node, ViewstampedReplication, :status, [:concord_cluster, node])
      end)

    with true <- Enum.all?(results, &match?({:ok, %{status: :normal}}, &1)),
         [primary] <-
           results
           |> Enum.map(fn {:ok, status} -> status.primary_id end)
           |> Enum.uniq() do
      {:ok, primary}
    else
      _not_ready -> :retry
    end
  end

  defp assert_strong_value(nodes, key, value) do
    assert :ok =
             eventually(fn ->
               results =
                 Enum.map(nodes, fn node ->
                   :rpc.call(node, Concord, :get, [key, [consistency: :strong]])
                 end)

               if Enum.all?(results, &(&1 == {:ok, value})), do: :ok, else: :retry
             end)
  end

  defp assert_all(nodes, module, function, args, expected) do
    assert Enum.all?(nodes, fn node ->
             :rpc.call(node, module, function, args) == expected
           end)
  end

  defp eventually(function) do
    deadline = System.monotonic_time(:millisecond) + @timeout
    eventually(function, deadline)
  end

  defp eventually(function, deadline) do
    case function.() do
      :retry ->
        retry(function, deadline)

      {:badrpc, _reason} ->
        retry(function, deadline)

      {:error, _reason} ->
        retry(function, deadline)

      result ->
        result
    end
  end

  defp retry(function, deadline) do
    if System.monotonic_time(:millisecond) < deadline do
      Process.sleep(200)
      eventually(function, deadline)
    else
      {:error, :timeout}
    end
  end

  defp wait_until(function) do
    eventually(fn -> if function.(), do: :ok, else: :retry end)
  end

  defp unique_key(prefix) do
    "e2e:vsr:#{prefix}:#{System.unique_integer([:positive, :monotonic])}"
  end
end
