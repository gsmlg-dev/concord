defmodule Concord.Sync do
  @moduledoc """
  Public API for Concord's sync and watch protocol.

  ## Pull model — `changes/3`

      events = Concord.Sync.changes(1840, 1850)

  ## Push model — `watch/2`

      {:ok, ref} = Concord.Sync.watch({:prefix, "/tasks/"}, self())

      receive do
        {:concord_event, ^ref, %Event{}} -> ...
      end

      :ok = Concord.Sync.unwatch(ref)

  ## Stream wrapper — `watch_stream/2`

      Concord.Sync.watch_stream({:prefix, "/tasks/"})
      |> Stream.each(&IO.inspect/1)
      |> Stream.run()
  """

  alias Concord.KV.Selector
  alias Concord.Sync.{ChangeLog, Event, WatchHub}

  @doc """
  Returns events in the revision range `[from, to]` (inclusive).

  ## Options

  - `:limit` — max events to return (default: 1000)
  """
  @spec changes(non_neg_integer(), non_neg_integer(), keyword()) :: [Event.t()]
  def changes(from_revision, to_revision, opts \\ []) do
    ChangeLog.changes(from_revision, to_revision, opts)
  end

  @doc """
  Subscribes the given process to events matching the selector.

  Returns `{:ok, watch_ref}`.

  ## Options

  - `:max_queue` — max pending events before backpressure (default: 1000)
  """
  @spec watch(Selector.t(), pid(), keyword()) :: {:ok, reference()} | {:error, term()}
  def watch(selector, subscriber_pid \\ self(), opts \\ []) do
    WatchHub.subscribe(selector, subscriber_pid, opts)
  end

  @doc """
  Unsubscribes a watch by its reference.
  """
  @spec unwatch(reference()) :: :ok
  def unwatch(watch_ref) do
    WatchHub.unsubscribe(watch_ref)
  end

  @doc """
  Returns a `Stream` that yields events matching the selector.

  The stream blocks on `receive` and yields one event at a time.
  Terminates when the calling process receives `:concord_watch_done`.
  """
  @spec watch_stream(Selector.t(), keyword()) :: Enumerable.t()
  def watch_stream(selector, opts \\ []) do
    Stream.resource(
      fn ->
        {:ok, ref} = watch(selector, self(), opts)
        ref
      end,
      fn ref ->
        receive do
          {:concord_event, ^ref, event} ->
            {[event], ref}

          {:concord_slow_consumer, ^ref} ->
            {[:slow_consumer], ref}

          :concord_watch_done ->
            {:halt, ref}
        end
      end,
      fn ref ->
        unwatch(ref)
      end
    )
  end

  @doc """
  Returns the earliest revision still in the change log.
  """
  @spec earliest_revision() :: non_neg_integer()
  def earliest_revision do
    ChangeLog.earliest_revision()
  end

  @doc """
  Compacts the change log, removing entries before `keep_revision`.
  """
  @spec compact(non_neg_integer()) :: non_neg_integer()
  def compact(keep_revision) do
    ChangeLog.compact(keep_revision)
  end

  @doc """
  Returns the number of active watchers.
  """
  @spec watcher_count() :: non_neg_integer()
  def watcher_count do
    WatchHub.count()
  end
end
