defmodule ViewstampedReplication.Log do
  @moduledoc """
  An immutable, contiguous VSR operation log.
  """

  alias ViewstampedReplication.LogEntry

  defstruct base_op_number: 0, entries: []

  @type t :: %__MODULE__{
          base_op_number: non_neg_integer(),
          entries: [LogEntry.t()]
        }

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec new([LogEntry.t()]) :: {:ok, t()} | {:error, term()}
  def new(entries) when is_list(entries) do
    new(0, entries)
  end

  @spec new(non_neg_integer(), [LogEntry.t()]) :: {:ok, t()} | {:error, term()}
  def new(base_op_number, entries)
      when is_integer(base_op_number) and base_op_number >= 0 and is_list(entries) do
    Enum.reduce_while(entries, {:ok, %__MODULE__{base_op_number: base_op_number}}, fn
      entry, {:ok, log} ->
        case append(log, entry) do
          {:ok, updated_log} -> {:cont, {:ok, updated_log}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
    end)
  end

  @spec append(t(), LogEntry.t()) :: {:ok, t()} | {:error, term()}
  def append(%__MODULE__{} = log, %LogEntry{op_number: op_number} = entry) do
    expected_op_number = last_op_number(log) + 1

    if op_number == expected_op_number do
      {:ok, %{log | entries: log.entries ++ [entry]}}
    else
      {:error, {:non_contiguous_op_number, expected_op_number, op_number}}
    end
  end

  @spec append!(t(), LogEntry.t()) :: t()
  def append!(%__MODULE__{} = log, %LogEntry{} = entry) do
    case append(log, entry) do
      {:ok, updated_log} -> updated_log
      {:error, reason} -> raise ArgumentError, "cannot append log entry: #{inspect(reason)}"
    end
  end

  @spec fetch(t(), pos_integer()) :: {:ok, LogEntry.t()} | :compacted | :error
  def fetch(%__MODULE__{base_op_number: base, entries: entries}, op_number)
      when is_integer(op_number) and op_number > 0 do
    case op_number do
      compacted when compacted <= base -> :compacted
      available -> fetch_entry(entries, available)
    end
  end

  @spec fetch!(t(), pos_integer()) :: LogEntry.t()
  def fetch!(%__MODULE__{} = log, op_number) do
    case fetch(log, op_number) do
      {:ok, entry} -> entry
      :compacted -> raise KeyError, key: op_number, term: log
      :error -> raise KeyError, key: op_number, term: log
    end
  end

  @spec last(t()) :: LogEntry.t() | nil
  def last(%__MODULE__{entries: entries}), do: List.last(entries)

  @spec last_op_number(t()) :: non_neg_integer()
  def last_op_number(%__MODULE__{base_op_number: base_op_number} = log) do
    case last(log) do
      nil -> base_op_number
      %LogEntry{op_number: op_number} -> op_number
    end
  end

  @spec to_list(t()) :: [LogEntry.t()]
  def to_list(%__MODULE__{entries: entries}), do: entries

  @spec suffix(t(), non_neg_integer()) :: [LogEntry.t()]
  def suffix(%__MODULE__{base_op_number: base, entries: entries}, after_op_number)
      when is_integer(after_op_number) and after_op_number >= 0 do
    Enum.drop(entries, max(after_op_number - base, 0))
  end

  @spec truncate_suffix(t(), non_neg_integer()) :: t()
  def truncate_suffix(%__MODULE__{base_op_number: base, entries: entries} = log, last_op_number)
      when is_integer(last_op_number) and last_op_number >= 0 do
    %{log | entries: Enum.take(entries, max(last_op_number - base, 0))}
  end

  @spec compact(t(), non_neg_integer()) :: {:ok, t()} | {:error, term()}
  def compact(%__MODULE__{base_op_number: base} = log, through_op_number)
      when is_integer(through_op_number) and through_op_number >= 0 do
    cond do
      through_op_number < base ->
        {:error, {:snapshot_before_compacted_prefix, base, through_op_number}}

      through_op_number > last_op_number(log) ->
        {:error, {:snapshot_ahead_of_log, last_op_number(log), through_op_number}}

      true ->
        {:ok,
         %{
           log
           | base_op_number: through_op_number,
             entries: suffix(log, through_op_number)
         }}
    end
  end

  defp fetch_entry(entries, op_number) do
    case entries do
      [] ->
        :error

      [%LogEntry{op_number: first} | _rest] ->
        case Enum.at(entries, op_number - first) do
          nil -> :error
          entry -> {:ok, entry}
        end
    end
  end
end
