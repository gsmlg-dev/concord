defmodule ViewstampedReplication.Log do
  @moduledoc """
  An immutable, contiguous VSR operation log.
  """

  alias ViewstampedReplication.LogEntry
  alias ViewstampedReplication.Log.Indexed

  defstruct base_op_number: 0, entries: []

  @type t :: %__MODULE__{
          base_op_number: non_neg_integer(),
          entries: [LogEntry.t()]
        }

  @type runtime_log :: t() | Indexed.t()

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec new([LogEntry.t()]) :: {:ok, t()} | {:error, term()}
  def new(entries) when is_list(entries) do
    new(0, entries)
  end

  @spec new(non_neg_integer(), [LogEntry.t()]) :: {:ok, t()} | {:error, term()}
  def new(base_op_number, entries)
      when is_integer(base_op_number) and base_op_number >= 0 and is_list(entries) do
    with :ok <- validate_entries(entries, base_op_number + 1) do
      {:ok, %__MODULE__{base_op_number: base_op_number, entries: entries}}
    end
  end

  @doc false
  @spec indexed(t()) :: Indexed.t()
  def indexed(%__MODULE__{base_op_number: base, entries: entries}) do
    %Indexed{
      base_op_number: base,
      last_op_number: base + length(entries),
      entries: Map.new(entries, &{&1.op_number, &1})
    }
  end

  @doc false
  @spec canonical(runtime_log()) :: t()
  def canonical(%__MODULE__{} = log), do: log

  def canonical(%Indexed{base_op_number: base, last_op_number: last, entries: entries}) do
    valid? =
      is_integer(base) and base >= 0 and is_integer(last) and last >= base and
        is_map(entries) and map_size(entries) == last - base and
        Enum.all?(entries, fn
          {position, %LogEntry{op_number: position}} ->
            is_integer(position) and position > base and position <= last

          _entry ->
            false
        end)

    unless valid?, do: raise(ArgumentError, "invalid indexed log")

    %__MODULE__{
      base_op_number: base,
      entries: for(position <- (base + 1)..last//1, do: Map.fetch!(entries, position))
    }
  end

  @spec append(runtime_log(), LogEntry.t()) :: {:ok, runtime_log()} | {:error, term()}
  def append(%Indexed{last_op_number: last} = log, %LogEntry{op_number: op_number} = entry) do
    if op_number == last + 1 do
      {:ok, %{log | last_op_number: op_number, entries: Map.put(log.entries, op_number, entry)}}
    else
      {:error, {:non_contiguous_op_number, last + 1, op_number}}
    end
  end

  def append(%__MODULE__{} = log, %LogEntry{op_number: op_number} = entry) do
    expected_op_number = last_op_number(log) + 1

    if op_number == expected_op_number do
      {:ok, %{log | entries: log.entries ++ [entry]}}
    else
      {:error, {:non_contiguous_op_number, expected_op_number, op_number}}
    end
  end

  @spec append!(runtime_log(), LogEntry.t()) :: runtime_log()
  def append!(log, %LogEntry{} = entry) do
    case append(log, entry) do
      {:ok, updated_log} -> updated_log
      {:error, reason} -> raise ArgumentError, "cannot append log entry: #{inspect(reason)}"
    end
  end

  @spec fetch(runtime_log(), pos_integer()) :: {:ok, LogEntry.t()} | :compacted | :error
  def fetch(%Indexed{base_op_number: base, entries: entries}, op_number)
      when is_integer(op_number) and op_number > 0 do
    if op_number <= base, do: :compacted, else: Map.fetch(entries, op_number)
  end

  def fetch(%__MODULE__{base_op_number: base, entries: entries}, op_number)
      when is_integer(op_number) and op_number > 0 do
    case op_number do
      compacted when compacted <= base -> :compacted
      available -> fetch_entry(entries, available)
    end
  end

  @spec fetch!(runtime_log(), pos_integer()) :: LogEntry.t()
  def fetch!(log, op_number) do
    case fetch(log, op_number) do
      {:ok, entry} -> entry
      :compacted -> raise KeyError, key: op_number, term: log
      :error -> raise KeyError, key: op_number, term: log
    end
  end

  @spec last(runtime_log()) :: LogEntry.t() | nil
  def last(%Indexed{last_op_number: last, entries: entries}), do: Map.get(entries, last)
  def last(%__MODULE__{entries: entries}), do: List.last(entries)

  @spec last_op_number(runtime_log()) :: non_neg_integer()
  def last_op_number(%Indexed{last_op_number: last}), do: last

  def last_op_number(%__MODULE__{base_op_number: base_op_number} = log) do
    case last(log) do
      nil -> base_op_number
      %LogEntry{op_number: op_number} -> op_number
    end
  end

  @spec to_list(runtime_log()) :: [LogEntry.t()]
  def to_list(%Indexed{} = log), do: canonical(log).entries
  def to_list(%__MODULE__{entries: entries}), do: entries

  @spec suffix(runtime_log(), non_neg_integer()) :: [LogEntry.t()]
  def suffix(%Indexed{} = log, after_op_number), do: suffix(canonical(log), after_op_number)

  def suffix(%__MODULE__{base_op_number: base, entries: entries}, after_op_number)
      when is_integer(after_op_number) and after_op_number >= 0 do
    Enum.drop(entries, max(after_op_number - base, 0))
  end

  @spec truncate_suffix(runtime_log(), non_neg_integer()) :: runtime_log()
  def truncate_suffix(%Indexed{} = log, last_op_number),
    do: log |> canonical() |> truncate_suffix(last_op_number) |> indexed()

  def truncate_suffix(%__MODULE__{base_op_number: base, entries: entries} = log, last_op_number)
      when is_integer(last_op_number) and last_op_number >= 0 do
    %{log | entries: Enum.take(entries, max(last_op_number - base, 0))}
  end

  @spec compact(runtime_log(), non_neg_integer()) :: {:ok, runtime_log()} | {:error, term()}
  def compact(%Indexed{} = log, through_op_number) do
    with {:ok, compacted} <- compact(canonical(log), through_op_number),
         do: {:ok, indexed(compacted)}
  end

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

  defp validate_entries([], _expected), do: :ok

  defp validate_entries([%LogEntry{op_number: expected} | entries], expected),
    do: validate_entries(entries, expected + 1)

  defp validate_entries([%LogEntry{op_number: actual} | _entries], expected),
    do: {:error, {:non_contiguous_op_number, expected, actual}}

  defp validate_entries([entry | _entries], _expected), do: {:error, {:invalid_log_entry, entry}}

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
