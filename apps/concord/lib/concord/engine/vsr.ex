defmodule Concord.Engine.VSR do
  @moduledoc """
  Viewstamped Replication-backed Concord engine.

  Commands use a stable VSR client session. Queries use quorum-confirmed read
  barriers, so they remain linearizable without appending to the replicated
  log or sharing the client's one-outstanding-command limit.

  Replicated commands are recursively validated before contacting the VSR
  runtime. Commands containing functions, PIDs, ports, or references return
  `{:error, {:invalid_command, reason}}` and are never submitted to the log.
  The corresponding reasons are `:function_in_spec`, `:pid_in_spec`,
  `:port_in_spec`, and `:ref_in_spec`.

  Queries are admitted through a fixed schema before a read barrier is issued.
  Unsupported shapes return `{:error, :unsupported_query}`; unsafe terms return
  `{:error, {:invalid_query, reason}}`.
  """

  use GenServer

  @behaviour Concord.Engine

  alias Concord.CommandEnvelope
  alias Concord.CommandSchema
  alias Concord.QuerySchema
  alias Concord.Validation
  alias ViewstampedReplication.Configuration

  @timeout 5_000
  @call_overhead 200

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Concord.Engine
  def command(command, opts \\ []) do
    with :ok <- Validation.validate_command_size(command),
         :ok <- CommandSchema.validate_emission(command) do
      call({:command, command, timeout(opts)}, timeout(opts))
    end
  end

  @impl Concord.Engine
  def query(query, opts \\ []) do
    timeout = timeout(opts)

    with :ok <- validate_query(query),
         {:ok, configuration} <- call(:configuration, timeout) do
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
    configuration = Keyword.fetch!(opts, :configuration)
    command_version = Keyword.get(opts, :command_version, 0)
    wal_version = Keyword.get(opts, :wal_version, 1)

    cond do
      not CommandEnvelope.supported_version?(command_version) ->
        {:stop, {:unsupported_command_version, command_version}}

      wal_version not in [1, 2] ->
        {:stop, {:unsupported_wal_version, wal_version}}

      true ->
        {:ok,
         %{
           configuration: configuration,
           command_version: command_version,
           wal_version: wal_version,
           command_ready: command_version == 0
         }}
    end
  end

  @impl true
  def handle_call(
        {:command, command, timeout},
        _from,
        %{configuration: configuration, command_version: command_version} = state
      ) do
    case ensure_command_ready(state, command, timeout) do
      {:ok, ready_state} ->
        result =
          with :ok <- Validation.validate_command_size(command),
               :ok <- CommandSchema.validate_emission(command) do
            command = CommandSchema.normalize_emission(command)
            operation = CommandEnvelope.wrap(timestamp_ms(), command, command_version)
            issue(configuration, operation, timeout)
          end

        {:reply, result, ready_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:query, query, timeout}, _from, %{configuration: configuration} = state) do
    result =
      with :ok <- validate_query(query) do
        issue_read(configuration, {:concord_query, timestamp_ms(), query}, timeout)
      end

    {:reply, result, state}
  end

  def handle_call(:configuration, _from, %{configuration: configuration} = state) do
    {:reply, {:ok, configuration}, state}
  end

  def handle_call(
        {:status, timeout},
        _from,
        %{
          configuration: configuration,
          command_version: command_version,
          wal_version: wal_version
        } = state
      ) do
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
           command_version: command_version,
           wal_version: wal_version,
           node: node()
         }}
      else
        error -> normalize_error(error)
      end

    {:reply, result, state}
  end

  def handle_call(:members, _from, %{configuration: configuration} = state) do
    members = Enum.map(configuration.members, &{&1.id, &1.endpoint})
    {:reply, {:ok, members}, state}
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

  defp normalize_error({:error, :not_found}), do: {:error, :cluster_not_ready}
  defp normalize_error(result), do: result

  defp validate_query(query) do
    with :ok <- validate_safe_query(query),
         :ok <- QuerySchema.validate(query) do
      :ok
    end
  end

  defp validate_safe_query(query) do
    case Validation.validate_term(query) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_query, reason}}
    end
  end

  defp ensure_command_ready(
         %{command_version: 0},
         :reconcile_legacy_state,
         _timeout
       ),
       do: {:error, {:command_version_required, 1}}

  defp ensure_command_ready(%{command_ready: true} = state, _command, _timeout),
    do: {:ok, state}

  defp ensure_command_ready(
         %{configuration: configuration, command_version: 1} = state,
         command,
         timeout
       ) do
    case issue_read(configuration, {:concord_query, timestamp_ms(), :stats}, timeout) do
      {:ok, result} ->
        case unwrap_query_result(result) do
          %{
            legacy_indexes: legacy_indexes,
            legacy_state_conflict_count: conflict_count,
            legacy_state_conflicts: conflict_sample,
            legacy_state_reconciliation_required: reconciliation_required,
            legacy_state_representation: representation
          }
          when is_list(legacy_indexes) and is_integer(conflict_count) and conflict_count >= 0 and
                 is_list(conflict_sample) and is_boolean(reconciliation_required) ->
            status = %{
              count: conflict_count,
              sample: conflict_sample,
              representation: representation,
              required: reconciliation_required
            }

            command_readiness(state, command, legacy_indexes, status)

          _invalid_stats ->
            {:error, :invalid_storage_status}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp dropping_legacy_index?({:drop_index, name}, legacy_indexes), do: name in legacy_indexes
  defp dropping_legacy_index?(_command, _legacy_indexes), do: false

  defp command_readiness(state, command, legacy_indexes, status) do
    cond do
      legacy_indexes != [] and dropping_legacy_index?(command, legacy_indexes) ->
        {:ok, state}

      legacy_indexes != [] ->
        {:error, {:legacy_indexes_require_migration, legacy_indexes}}

      status.required and migration_command?(command) ->
        {:ok, state}

      status.required ->
        {:error, {:legacy_state_requires_reconciliation, status}}

      true ->
        {:ok, %{state | command_ready: true}}
    end
  end

  defp migration_command?(:reconcile_legacy_state), do: true
  defp migration_command?(_command), do: false

  defp unwrap_query_result({:ok, result}), do: result
  defp unwrap_query_result(result), do: result
end
