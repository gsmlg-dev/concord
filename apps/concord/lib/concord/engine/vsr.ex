defmodule Concord.Engine.VSR do
  @moduledoc """
  Viewstamped Replication-backed Concord engine.

  Commands use a stable VSR client session. Queries use quorum-confirmed read
  barriers, so they remain linearizable without appending to the replicated
  log or sharing the client's one-outstanding-command limit.
  """

  use GenServer

  @behaviour Concord.Engine

  alias ViewstampedReplication.Configuration

  @timeout 5_000
  @call_overhead 200

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Concord.Engine
  def command(command, opts \\ []) do
    call({:command, command, timeout(opts)}, timeout(opts))
  end

  @impl Concord.Engine
  def query(query, opts \\ []) do
    timeout = timeout(opts)

    with {:ok, configuration} <- call(:configuration, timeout) do
      issue_read(configuration, {:concord_query, timestamp_ms(), query}, timeout)
    end
  end

  @impl Concord.Engine
  def status(opts \\ []) do
    call({:status, timeout(opts)}, timeout(opts))
  end

  @impl Concord.Engine
  def members(opts \\ []) do
    call(:members, timeout(opts))
  end

  @impl true
  def init(opts) do
    {:ok, Keyword.fetch!(opts, :configuration)}
  end

  @impl true
  def handle_call({:command, command, timeout}, _from, configuration) do
    result = issue(configuration, {:concord_command, timestamp_ms(), command}, timeout)
    {:reply, result, configuration}
  end

  def handle_call({:query, query, timeout}, _from, configuration) do
    result = issue_read(configuration, {:concord_query, timestamp_ms(), query}, timeout)
    {:reply, result, configuration}
  end

  def handle_call(:configuration, _from, configuration) do
    {:reply, {:ok, configuration}, configuration}
  end

  def handle_call({:status, timeout}, _from, configuration) do
    result =
      with {:ok, cluster} <-
             ViewstampedReplication.status(
               configuration.group_id,
               configuration.replica_id
             ),
           {:ok, storage} <-
             issue_read(configuration, {:concord_query, timestamp_ms(), :stats}, timeout) do
        {:ok,
         %{
           cluster: cluster,
           storage: unwrap_query_result(storage),
           engine: :vsr,
           node: node()
         }}
      else
        error -> normalize_error(error)
      end

    {:reply, result, configuration}
  end

  def handle_call(:members, _from, configuration) do
    members = Enum.map(configuration.members, &{&1.id, &1.endpoint})
    {:reply, {:ok, members}, configuration}
  end

  defp issue(%Configuration{} = configuration, operation, timeout) do
    configuration.group_id
    |> ViewstampedReplication.command(operation,
      client: __MODULE__.Client,
      timeout: timeout
    )
    |> normalize_error()
  end

  defp issue_read(%Configuration{} = configuration, operation, timeout) do
    configuration.group_id
    |> ViewstampedReplication.read(operation,
      replica_id: configuration.replica_id,
      replicas: configuration.members,
      timeout: timeout
    )
    |> normalize_error()
  end

  defp call(request, timeout) do
    GenServer.call(__MODULE__, request, timeout + @call_overhead)
  catch
    :exit, {:timeout, _details} -> {:error, :timeout}
    :exit, {:noproc, _details} -> {:error, :cluster_not_ready}
    :exit, {:normal, _details} -> {:error, :cluster_not_ready}
    :exit, _reason -> {:error, :cluster_not_ready}
  end

  defp timeout(opts), do: Keyword.get(opts, :timeout, @timeout)
  defp timestamp_ms, do: System.system_time(:millisecond)

  defp normalize_error({:error, :quorum_unavailable}), do: {:error, :timeout}
  defp normalize_error({:error, :not_ready}), do: {:error, :timeout}
  defp normalize_error({:error, :not_found}), do: {:error, :cluster_not_ready}
  defp normalize_error(result), do: result

  defp unwrap_query_result({:ok, result}), do: result
  defp unwrap_query_result(result), do: result
end
