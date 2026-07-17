defmodule Concord.Engine.Cluster do
  @moduledoc """
  Raft-backed Concord engine.

  This is the existing Concord storage/concurrency model: writes are submitted
  to Ra via `:ra.process_command/3`, and reads use the configured Ra query
  consistency level.
  """

  @behaviour Concord.Engine

  alias Concord.StateMachine

  @timeout 5_000

  @impl true
  def command(command, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @timeout)

    case :ra.process_command(server_id(), command, timeout) do
      {:ok, result, _leader} -> {:ok, result}
      {:timeout, _} -> {:error, :timeout}
      {:error, :noproc} -> {:error, :cluster_not_ready}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def query(query, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @timeout)
    consistency = Keyword.get(opts, :consistency, default_consistency())
    mfa = {StateMachine, :query, [query]}

    result =
      case consistency do
        :eventual ->
          :ra.local_query(
            select_read_replica(),
            fn state -> StateMachine.query(query, state) end,
            timeout
          )

        :leader ->
          :ra.leader_query(server_id(), mfa, timeout)

        :strong ->
          :ra.consistent_query(server_id(), mfa, timeout)

        _ ->
          :ra.leader_query(server_id(), mfa, timeout)
      end

    case result do
      {:ok, {{_index, _term}, query_result}, _leader} -> {:ok, query_result}
      {:ok, query_result, _leader} -> {:ok, query_result}
      {:timeout, _} -> {:error, :timeout}
      {:error, :noproc} -> {:error, :cluster_not_ready}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def status(opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @timeout)

    with {:ok, overview, _} <- :ra.member_overview(server_id(), timeout),
         {:ok, {:ok, stats}} <- query(:stats, opts) do
      {:ok,
       %{
         cluster: make_json_friendly(overview),
         storage: stats,
         engine: :kv_cluster,
         node: node()
       }}
    else
      {:timeout, _} -> {:error, :timeout}
      {:error, :noproc} -> {:error, :cluster_not_ready}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def members(_opts \\ []) do
    case :ra.members(server_id()) do
      {:ok, members, _leader} -> {:ok, members}
      {:error, :noproc} -> {:error, :cluster_not_ready}
      {:error, reason} -> {:error, reason}
      {:timeout, _} -> {:error, :timeout}
    end
  end

  defp server_id do
    {Application.get_env(:concord, :cluster_name, :concord_cluster), node()}
  end

  defp default_consistency do
    Application.get_env(:concord, :default_read_consistency, :leader)
  end

  defp select_read_replica do
    case :ra.members(server_id()) do
      {:ok, [_ | _] = members, _leader} -> Enum.random(members)
      _ -> server_id()
    end
  end

  defp make_json_friendly(data) when is_map(data) do
    data
    |> Enum.map(fn {key, value} -> {make_json_friendly(key), make_json_friendly(value)} end)
    |> Map.new()
  end

  defp make_json_friendly(data) when is_list(data), do: Enum.map(data, &make_json_friendly/1)
  defp make_json_friendly(data) when is_tuple(data), do: inspect(data)

  defp make_json_friendly(data) when is_reference(data) or is_pid(data) or is_port(data) do
    inspect(data)
  end

  defp make_json_friendly(data), do: data
end
