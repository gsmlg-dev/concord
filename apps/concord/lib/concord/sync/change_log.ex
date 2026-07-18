defmodule Concord.Sync.ChangeLog do
  @moduledoc """
  ETS-backed bounded change log for Concord.

  Stores `%Event{}` records keyed by `{revision, op_index}` in an
  `:ordered_set` ETS table. Supports range queries for historical replay
  and automatic compaction to bound memory usage.
  """

  alias Concord.Sync.Event

  @table :concord_change_log
  @default_max_entries 100_000

  @doc """
  Ensures the change log ETS table exists.
  """
  def ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:ordered_set, :named_table, :public])

      _table ->
        :ok
    end
  end

  @doc """
  Appends events to the change log. Called from the state machine
  on every mutation.
  """
  @spec append([Event.t()]) :: :ok
  def append(events) when is_list(events) do
    events
    |> Enum.with_index()
    |> Enum.each(fn {%Event{} = event, index} ->
      :ets.insert(@table, {event_key(event, index), event})
    end)

    maybe_compact()
    :ok
  end

  @doc false
  @spec append_new([Event.t()]) :: [Event.t()]
  def append_new(events) when is_list(events) do
    inserted =
      events
      |> Enum.with_index()
      |> Enum.reduce([], fn {%Event{} = event, index}, acc ->
        if :ets.insert_new(@table, {event_key(event, index), event}),
          do: [event | acc],
          else: acc
      end)
      |> Enum.reverse()

    maybe_compact()
    inserted
  end

  @doc """
  Returns events in the revision range `[from, to]` (inclusive).
  """
  @spec changes(non_neg_integer(), non_neg_integer(), keyword()) :: [Event.t()]
  def changes(from_revision, to_revision, opts \\ []) do
    limit = Keyword.get(opts, :limit, 1000)

    match_spec = [
      {{{:"$1", :"$2"}, :"$3"}, [{:>=, :"$1", from_revision}, {:"=<", :"$1", to_revision}],
       [:"$3"]}
    ]

    case :ets.whereis(@table) do
      :undefined ->
        []

      _ ->
        :ets.select(@table, match_spec)
        |> Enum.sort_by(&{&1.revision, &1.id})
        |> Enum.take(limit)
    end
  end

  @doc """
  Returns the earliest revision still in the change log, or `0` if empty.
  """
  @spec earliest_revision() :: non_neg_integer()
  def earliest_revision do
    case :ets.whereis(@table) do
      :undefined ->
        0

      _ ->
        case :ets.first(@table) do
          :"$end_of_table" -> 0
          {rev, _} -> rev
        end
    end
  end

  @doc """
  Compacts the change log to keep only entries after `keep_revision`.
  """
  @spec compact(non_neg_integer()) :: non_neg_integer()
  def compact(keep_revision) do
    case :ets.whereis(@table) do
      :undefined ->
        0

      _ ->
        match_spec = [
          {{{:"$1", :"$2"}, :_}, [{:<, :"$1", keep_revision}], [true]}
        ]

        :ets.select_delete(@table, match_spec)
    end
  end

  # Compact if over the configured max size
  defp maybe_compact do
    max = Application.get_env(:concord, :change_log_max_entries, @default_max_entries)

    case :ets.whereis(@table) do
      :undefined ->
        :ok

      _ ->
        size = :ets.info(@table, :size)

        if size > max do
          # Keep the latest 80% of entries
          keep = div(max * 4, 5)
          drop = size - keep

          keys =
            :ets.select(@table, [{{{:"$1", :"$2"}, :_}, [], [{{:"$1", :"$2"}}]}])
            |> Enum.sort()
            |> Enum.take(drop)

          Enum.each(keys, &:ets.delete(@table, &1))
        end

        :ok
    end
  end

  defp event_key(%Event{revision: revision, id: nil}, index),
    do: {revision, {:legacy, index}}

  defp event_key(%Event{revision: revision, id: id}, _index), do: {revision, id}
end
