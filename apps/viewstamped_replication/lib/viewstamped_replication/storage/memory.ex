defmodule ViewstampedReplication.Storage.Memory do
  @moduledoc """
  Volatile storage for protocol development and deterministic tests.
  """

  @behaviour ViewstampedReplication.Storage

  alias ViewstampedReplication.{Log, LogEntry}

  @enforce_keys [:configuration_hash, :replica_id]
  defstruct [
    :configuration_hash,
    :replica_id,
    hard_state: %{},
    log: %Log{},
    commit_number: 0,
    applied_number: 0,
    snapshot: nil,
    client_table: %{}
  ]

  @impl true
  def open(opts) do
    with {:ok, configuration_hash} <- Keyword.fetch(opts, :configuration_hash),
         {:ok, replica_id} <- Keyword.fetch(opts, :replica_id) do
      {:ok,
       %__MODULE__{
         configuration_hash: configuration_hash,
         replica_id: replica_id
       }}
    else
      :error -> {:error, :storage_identity_required}
    end
  end

  @impl true
  def recover(%__MODULE__{} = state), do: {:ok, recovered(state), state}

  @impl true
  def persist_hard_state(%__MODULE__{} = state, hard_state) when is_map(hard_state),
    do: {:ok, %{state | hard_state: Map.merge(state.hard_state, hard_state)}}

  @impl true
  def append(%__MODULE__{} = state, %LogEntry{} = entry), do: append(state, [entry])

  def append(%__MODULE__{} = state, entries) when is_list(entries) do
    with {:ok, log} <- append_entries(state.log, entries) do
      {:ok, %{state | log: log}}
    end
  end

  @impl true
  def truncate_suffix(%__MODULE__{} = state, last_op_number)
      when is_integer(last_op_number) and last_op_number >= 0 do
    cond do
      last_op_number < state.commit_number ->
        {:error, :cannot_truncate_committed_entry}

      last_op_number < state.log.base_op_number ->
        {:error, :cannot_truncate_compacted_prefix}

      true ->
        {:ok, %{state | log: Log.truncate_suffix(state.log, last_op_number)}}
    end
  end

  @impl true
  def set_commit_number(%__MODULE__{} = state, commit_number)
      when is_integer(commit_number) and commit_number >= 0 do
    cond do
      commit_number < state.commit_number -> {:error, :commit_number_decreased}
      commit_number > Log.last_op_number(state.log) -> {:error, :commit_number_ahead_of_log}
      true -> {:ok, %{state | commit_number: commit_number}}
    end
  end

  @impl true
  def set_applied(%__MODULE__{} = state, applied_number, client_table)
      when is_integer(applied_number) and applied_number >= 0 and is_map(client_table) do
    cond do
      applied_number < state.applied_number -> {:error, :applied_number_decreased}
      applied_number > state.commit_number -> {:error, :applied_number_ahead_of_commit}
      true -> {:ok, %{state | applied_number: applied_number, client_table: client_table}}
    end
  end

  @impl true
  def write_snapshot(%__MODULE__{} = state, snapshot),
    do: {:ok, %{state | snapshot: snapshot}}

  @impl true
  def install_snapshot(%__MODULE__{} = state, snapshot),
    do: {:ok, %{state | snapshot: snapshot}}

  @impl true
  def install_state(%__MODULE__{} = state, durable_state) when is_map(durable_state) do
    log =
      case Map.get(durable_state, :log, []) do
        %Log{} = log -> validate_log(log)
        entries when is_list(entries) -> Log.new(entries)
      end

    commit_number = Map.get(durable_state, :commit_number, 0)
    requested_applied_number = Map.get(durable_state, :applied_number, state.applied_number)

    with {:ok, log} <- log,
         applied_number <- max(requested_applied_number, log.base_op_number),
         true <-
           commit_number >= log.base_op_number or
             {:error, :commit_number_behind_compacted_prefix},
         true <-
           commit_number <= Log.last_op_number(log) or {:error, :commit_number_ahead_of_log},
         true <- applied_number <= commit_number or {:error, :applied_number_ahead_of_commit} do
      hard_state =
        Map.merge(
          state.hard_state,
          Map.take(durable_state, [:view_number, :last_normal_view, :status, :applied_number])
        )

      {:ok,
       %{
         state
         | hard_state: hard_state,
           log: log,
           commit_number: commit_number,
           applied_number: applied_number,
           client_table: Map.get(durable_state, :client_table, %{})
       }}
    end
  end

  @impl true
  def close(%__MODULE__{}), do: :ok

  defp recovered(state) do
    %{
      configuration_hash: state.configuration_hash,
      replica_id: state.replica_id,
      hard_state: state.hard_state,
      log: state.log,
      commit_number: state.commit_number,
      applied_number: state.applied_number,
      snapshot: state.snapshot,
      client_table: state.client_table
    }
  end

  defp append_entries(log, entries) do
    Enum.reduce_while(entries, {:ok, log}, fn
      %LogEntry{} = entry, {:ok, log} ->
        case Log.append(log, entry) do
          {:ok, log} -> {:cont, {:ok, log}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      entry, {:ok, _log} ->
        {:halt, {:error, {:invalid_log_entry, entry}}}
    end)
  end

  defp validate_log(%Log{base_op_number: base, entries: entries}),
    do: Log.new(base, entries)
end
