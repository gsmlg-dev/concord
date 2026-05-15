defmodule Concord.Sync.WatchHubTest do
  use ExUnit.Case, async: false

  alias Concord.Sync.{Event, WatchHub}

  setup do
    # Start fresh WatchHub
    case GenServer.whereis(WatchHub) do
      nil ->
        {:ok, _} = WatchHub.start_link()

      pid ->
        # Reset state by stopping and restarting
        GenServer.stop(pid, :normal)
        Process.sleep(50)
        {:ok, _} = WatchHub.start_link()
    end

    :ok
  end

  describe "subscribe/unsubscribe" do
    test "subscribes and gets a reference" do
      {:ok, ref} = WatchHub.subscribe({:key, "test"}, self())
      assert is_reference(ref)
    end

    test "unsubscribe returns :ok" do
      {:ok, ref} = WatchHub.subscribe({:key, "test"}, self())
      assert :ok = WatchHub.unsubscribe(ref)
    end

    test "unsubscribe unknown ref is a no-op" do
      assert :ok = WatchHub.unsubscribe(make_ref())
    end

    test "count returns active watcher count" do
      {:ok, _} = WatchHub.subscribe({:key, "a"}, self())
      {:ok, _} = WatchHub.subscribe({:key, "b"}, self())
      assert WatchHub.count() == 2
    end

    test "unsubscribe decreases count" do
      {:ok, ref} = WatchHub.subscribe({:key, "a"}, self())
      {:ok, _} = WatchHub.subscribe({:key, "b"}, self())
      WatchHub.unsubscribe(ref)
      assert WatchHub.count() == 1
    end
  end

  describe "notify/1" do
    test "delivers matching events to subscriber" do
      {:ok, ref} = WatchHub.subscribe({:key, "watched"}, self())

      event = %Event{type: :put, key: "watched", revision: 1, record: nil, prev_record: nil}
      WatchHub.notify([event])

      assert_receive {:concord_event, ^ref, ^event}, 1000
    end

    test "does not deliver non-matching events" do
      {:ok, ref} = WatchHub.subscribe({:key, "watched"}, self())

      event = %Event{type: :put, key: "other", revision: 1, record: nil, prev_record: nil}
      WatchHub.notify([event])

      refute_receive {:concord_event, ^ref, _}, 200
    end

    test "prefix selector matches" do
      {:ok, ref} = WatchHub.subscribe({:prefix, "/tasks/"}, self())

      event = %Event{type: :put, key: "/tasks/123", revision: 1, record: nil, prev_record: nil}
      WatchHub.notify([event])

      assert_receive {:concord_event, ^ref, ^event}, 1000
    end

    test "prefix selector rejects non-matching" do
      {:ok, ref} = WatchHub.subscribe({:prefix, "/tasks/"}, self())

      event = %Event{type: :put, key: "/jobs/123", revision: 1, record: nil, prev_record: nil}
      WatchHub.notify([event])

      refute_receive {:concord_event, ^ref, _}, 200
    end

    test "range selector matches" do
      {:ok, ref} = WatchHub.subscribe({:range, "a", "d"}, self())

      event = %Event{type: :put, key: "b", revision: 1, record: nil, prev_record: nil}
      WatchHub.notify([event])

      assert_receive {:concord_event, ^ref, ^event}, 1000
    end
  end

  describe "auto-cleanup on subscriber DOWN" do
    test "removes watcher when subscriber dies" do
      {pid, monitor_ref} =
        spawn_monitor(fn ->
          receive do
            :stop -> :ok
          end
        end)

      {:ok, _ref} = WatchHub.subscribe({:key, "test"}, pid)
      assert WatchHub.count() == 1

      send(pid, :stop)
      receive do: ({:DOWN, ^monitor_ref, :process, _, _} -> :ok)

      # Give WatchHub time to process the DOWN message
      Process.sleep(100)
      assert WatchHub.count() == 0
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
