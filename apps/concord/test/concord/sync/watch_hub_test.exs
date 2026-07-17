defmodule Concord.Sync.WatchHubTest do
  use ExUnit.Case, async: false

  alias Concord.Sync.{Event, WatchHub}

  setup do
    # In CI the application supervisor has already started WatchHub,
    # so we just clear existing watchers instead of restarting the process.
    case GenServer.whereis(WatchHub) do
      nil ->
        {:ok, _} = WatchHub.start_link()

      _pid ->
        # WatchHub is already running (started by supervisor in CI).
        # Unsubscribe any leftover watchers from previous tests.
        :ok
    end

    :ok
  end

  describe "subscribe/unsubscribe" do
    test "subscribes and gets a reference" do
      {:ok, ref} = WatchHub.subscribe({:key, "test"}, self())
      assert is_reference(ref)
      WatchHub.unsubscribe(ref)
    end

    test "unsubscribe returns :ok" do
      {:ok, ref} = WatchHub.subscribe({:key, "test"}, self())
      assert :ok = WatchHub.unsubscribe(ref)
    end

    test "unsubscribe unknown ref is a no-op" do
      assert :ok = WatchHub.unsubscribe(make_ref())
    end

    test "count increases on subscribe" do
      initial = WatchHub.count()
      {:ok, ref1} = WatchHub.subscribe({:key, "a"}, self())
      {:ok, ref2} = WatchHub.subscribe({:key, "b"}, self())
      assert WatchHub.count() == initial + 2
      WatchHub.unsubscribe(ref1)
      WatchHub.unsubscribe(ref2)
    end

    test "unsubscribe decreases count" do
      {:ok, ref} = WatchHub.subscribe({:key, "a"}, self())
      {:ok, ref2} = WatchHub.subscribe({:key, "b"}, self())
      before = WatchHub.count()
      WatchHub.unsubscribe(ref)
      assert WatchHub.count() == before - 1
      WatchHub.unsubscribe(ref2)
    end
  end

  describe "notify/1" do
    test "delivers matching events to subscriber" do
      {:ok, ref} = WatchHub.subscribe({:key, "watched"}, self())

      event = %Event{type: :put, key: "watched", revision: 1, record: nil, prev_record: nil}
      WatchHub.notify([event])

      assert_receive {:concord_event, ^ref, ^event}, 1000
      WatchHub.unsubscribe(ref)
    end

    test "does not deliver non-matching events" do
      {:ok, ref} = WatchHub.subscribe({:key, "watched"}, self())

      event = %Event{type: :put, key: "other", revision: 1, record: nil, prev_record: nil}
      WatchHub.notify([event])

      refute_receive {:concord_event, ^ref, _}, 200
      WatchHub.unsubscribe(ref)
    end

    test "prefix selector matches" do
      {:ok, ref} = WatchHub.subscribe({:prefix, "/tasks/"}, self())

      event = %Event{type: :put, key: "/tasks/123", revision: 1, record: nil, prev_record: nil}
      WatchHub.notify([event])

      assert_receive {:concord_event, ^ref, ^event}, 1000
      WatchHub.unsubscribe(ref)
    end

    test "prefix selector rejects non-matching" do
      {:ok, ref} = WatchHub.subscribe({:prefix, "/tasks/"}, self())

      event = %Event{type: :put, key: "/jobs/123", revision: 1, record: nil, prev_record: nil}
      WatchHub.notify([event])

      refute_receive {:concord_event, ^ref, _}, 200
      WatchHub.unsubscribe(ref)
    end

    test "range selector matches" do
      {:ok, ref} = WatchHub.subscribe({:range, "a", "d"}, self())

      event = %Event{type: :put, key: "b", revision: 1, record: nil, prev_record: nil}
      WatchHub.notify([event])

      assert_receive {:concord_event, ^ref, ^event}, 1000
      WatchHub.unsubscribe(ref)
    end
  end

  describe "auto-cleanup on subscriber DOWN" do
    test "removes watcher when subscriber dies" do
      before_count = WatchHub.count()

      {pid, monitor_ref} =
        spawn_monitor(fn ->
          receive do
            :stop -> :ok
          end
        end)

      {:ok, _ref} = WatchHub.subscribe({:key, "test"}, pid)
      assert WatchHub.count() == before_count + 1

      send(pid, :stop)
      receive do: ({:DOWN, ^monitor_ref, :process, _, _} -> :ok)

      # Give WatchHub time to process the DOWN message
      Process.sleep(100)
      assert WatchHub.count() == before_count
    end
  end

  describe "rejects invalid selectors" do
    test "rejects empty key" do
      assert {:error, :empty_key} = WatchHub.subscribe({:key, ""}, self())
    end

    test "rejects inverted range" do
      assert {:error, :invalid_range} = WatchHub.subscribe({:range, "z", "a"}, self())
    end
  end
end
