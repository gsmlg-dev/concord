defmodule ViewstampedReplication.Storage do
  @moduledoc """
  Durable-state adapter contract used by a replica runtime.

  Adapter state is owned by the replica process. Mutating callbacks return the
  updated adapter state so storage implementations do not need a process of
  their own. `install_snapshot_state/3` must make the transferred snapshot and
  its matching protocol log, counters, and client table crash-atomic; exposing
  either half independently can make a replica unrecoverable.
  """

  alias ViewstampedReplication.{Log, LogEntry}

  @type recovered_state :: %{
          required(:configuration_hash) => binary(),
          required(:replica_id) => term(),
          required(:hard_state) => map(),
          required(:log) => Log.t(),
          required(:commit_number) => non_neg_integer(),
          required(:applied_number) => non_neg_integer(),
          required(:snapshot) => term() | nil,
          required(:client_table) => map()
        }

  @callback open(keyword()) :: {:ok, term()} | {:error, term()}
  @callback recover(term()) :: {:ok, recovered_state(), term()} | {:error, term()}
  @callback persist_hard_state(term(), map()) :: {:ok, term()} | {:error, term()}
  @callback append(term(), LogEntry.t() | [LogEntry.t()]) :: {:ok, term()} | {:error, term()}
  @callback truncate_suffix(term(), non_neg_integer()) :: {:ok, term()} | {:error, term()}
  @callback set_commit_number(term(), non_neg_integer()) :: {:ok, term()} | {:error, term()}
  @callback set_applied(term(), non_neg_integer(), map()) ::
              {:ok, term()} | {:error, term()}
  @callback write_snapshot(term(), term()) :: {:ok, term()} | {:error, term()}
  @callback install_snapshot(term(), term()) :: {:ok, term()} | {:error, term()}
  @callback install_snapshot_state(term(), term(), map()) ::
              {:ok, term()} | {:error, term()}
  @callback install_state(term(), map()) :: {:ok, term()} | {:error, term()}
  @callback close(term()) :: :ok | {:error, term()}

  @spec validate_recovered(term()) :: :ok | {:error, {:invalid_recovered_state, term()}}
  def validate_recovered(recovered) do
    case do_validate_recovered(recovered) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_recovered_state, reason}}
    end
  end

  defp do_validate_recovered(%{
         configuration_hash: configuration_hash,
         replica_id: _replica_id,
         hard_state: hard_state,
         log: log,
         commit_number: commit_number,
         applied_number: applied_number,
         snapshot: snapshot,
         client_table: client_table
       }) do
    with true <- is_binary(configuration_hash) or {:error, :invalid_configuration_hash},
         true <- is_map(hard_state) or {:error, :invalid_hard_state},
         :ok <- validate_hard_state(hard_state),
         {:ok, log} <- validate_log(log),
         :ok <- validate_log_views(log, Map.get(hard_state, :view_number, 0)),
         :ok <- validate_operation_numbers(log, commit_number, applied_number),
         :ok <- validate_snapshot(log, snapshot, applied_number),
         :ok <- validate_client_table(client_table, log, applied_number) do
      :ok
    end
  end

  defp do_validate_recovered(_recovered), do: {:error, :invalid_structure}

  defp validate_hard_state(hard_state) do
    view_number = Map.get(hard_state, :view_number, 0)
    last_normal_view = Map.get(hard_state, :last_normal_view, 0)
    status = Map.get(hard_state, :status, :recovering)
    applied_number = Map.get(hard_state, :applied_number, 0)

    cond do
      not is_integer(view_number) or view_number < 0 ->
        {:error, :invalid_view_number}

      not is_integer(last_normal_view) or last_normal_view < 0 ->
        {:error, :invalid_last_normal_view}

      last_normal_view > view_number ->
        {:error, :last_normal_view_ahead}

      status not in [:normal, :view_change, :recovering] ->
        {:error, :invalid_status}

      not is_integer(applied_number) or applied_number < 0 ->
        {:error, :invalid_hard_state_applied_number}

      true ->
        :ok
    end
  end

  defp validate_log(%Log{base_op_number: base, entries: entries})
       when is_integer(base) and base >= 0 and is_list(entries) do
    case Log.new(base, entries) do
      {:ok, log} ->
        if Enum.all?(entries, &valid_log_entry?/1) and unique_client_requests?(entries),
          do: {:ok, log},
          else: {:error, :invalid_log_entry}

      {:error, _reason} ->
        {:error, :invalid_log}
    end
  end

  defp validate_log(entries) when is_list(entries), do: validate_log(%Log{entries: entries})
  defp validate_log(_log), do: {:error, :invalid_log}

  defp valid_log_entry?(%LogEntry{
         view_number: view_number,
         op_number: op_number,
         request_number: request_number,
         metadata: metadata
       }),
       do:
         is_integer(view_number) and view_number >= 0 and is_integer(op_number) and
           op_number > 0 and is_integer(request_number) and request_number >= 0 and
           is_map(metadata)

  defp valid_log_entry?(_entry), do: false

  defp unique_client_requests?(entries) do
    requests = Enum.map(entries, &{&1.client_id, &1.request_number})
    MapSet.size(MapSet.new(requests)) == length(requests)
  end

  defp validate_log_views(%Log{} = log, view_number) do
    if Enum.all?(Log.to_list(log), &(&1.view_number <= view_number)),
      do: :ok,
      else: {:error, :log_entry_from_future_view}
  end

  defp validate_operation_numbers(log, commit_number, applied_number) do
    base = log.base_op_number
    last = Log.last_op_number(log)

    cond do
      not is_integer(commit_number) or commit_number < base or commit_number > last ->
        {:error, :invalid_commit_number}

      not is_integer(applied_number) or applied_number < base or
          applied_number > commit_number ->
        {:error, :invalid_applied_number}

      true ->
        :ok
    end
  end

  defp validate_snapshot(%Log{base_op_number: base}, nil, _applied_number) do
    if base == 0, do: :ok, else: {:error, :missing_compacted_snapshot}
  end

  defp validate_snapshot(%Log{base_op_number: base}, snapshot, applied_number) do
    snapshot_op_number =
      case snapshot do
        %{last_op_number: op_number} when is_integer(op_number) and op_number >= 0 -> op_number
        %{op_number: op_number} when is_integer(op_number) and op_number >= 0 -> op_number
        _snapshot -> 0
      end

    if snapshot_op_number >= base and snapshot_op_number <= applied_number,
      do: :ok,
      else: {:error, :invalid_snapshot_op_number}
  end

  defp validate_client_table(client_table, log, applied_number) when is_map(client_table) do
    records_valid? =
      Enum.all?(client_table, fn {client_id, record} ->
        valid_client_record?(record) and
          valid_client_record_position?(client_id, record, log, applied_number)
      end)

    if records_valid? and applied_client_records_complete?(client_table, log, applied_number),
      do: :ok,
      else: {:error, :invalid_client_table}
  end

  defp validate_client_table(_client_table, _log, _applied_number),
    do: {:error, :invalid_client_table}

  defp valid_client_record?(%{request_number: request_number, status: :pending}) do
    is_integer(request_number) and request_number >= 0
  end

  defp valid_client_record?(%{request_number: request_number, status: :applied} = record) do
    is_integer(request_number) and request_number >= 0 and Map.has_key?(record, :result)
  end

  defp valid_client_record?(_record), do: false

  defp valid_client_record_position?(
         client_id,
         %{request_number: request_number, status: status},
         log,
         applied_number
       ) do
    matching_entry =
      Enum.find(Log.to_list(log), fn entry ->
        entry.client_id == client_id and entry.request_number == request_number
      end)

    case {status, matching_entry} do
      {:pending, %LogEntry{op_number: op_number}} -> op_number > applied_number
      {:pending, nil} -> false
      {:applied, %LogEntry{op_number: op_number}} -> op_number <= applied_number
      {:applied, nil} -> true
    end
  end

  defp applied_client_records_complete?(client_table, log, applied_number) do
    log
    |> Log.to_list()
    |> Enum.reduce(%{}, fn entry, latest -> Map.put(latest, entry.client_id, entry) end)
    |> Enum.all?(fn
      {_client_id, %LogEntry{op_number: op_number}} when op_number > applied_number ->
        true

      {client_id, %LogEntry{request_number: request_number}} ->
        case Map.get(client_table, client_id) do
          %{status: :applied, request_number: recorded} -> recorded >= request_number
          _missing_or_pending -> false
        end
    end)
  end
end
