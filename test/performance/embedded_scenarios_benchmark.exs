defmodule Concord.Performance.EmbeddedScenariosBenchmark do
  @moduledoc """
  Realistic performance benchmarks for Concord as an embedded database.

  These benchmarks simulate common usage patterns in Elixir applications
  that would embed Concord as a dependency.
  """

  def run_embedded_benchmarks do
    IO.puts("🏗️  Concord Embedded Scenarios Benchmark")
    IO.puts("====================================")
    IO.puts("Testing realistic embedded application usage...")
    IO.puts("")

    setup_concord()

    # Run realistic embedded scenarios
    web_application_scenario()
    phoenix_session_store_scenario()
    configuration_management_scenario()
    feature_flag_scenario()
    caching_scenario()
    distributed_lock_scenario()
    pubsub_state_scenario()

    IO.puts("\n✅ All embedded scenario benchmarks completed!")
  end

  defp setup_concord do
    Application.ensure_all_started(:concord)
    :timer.sleep(1000)
    :ets.delete_all_objects(:concord_store)
    IO.puts("✅ Concord ready for embedded scenario testing")
  end

  def web_application_scenario do
    IO.puts("\n🌐 Web Application Scenario")
    IO.puts("==========================")

    # Simulate a web application storing user sessions, request counts, etc.
    IO.puts("Simulating web application with user sessions and analytics...")

    benchee_run(%{
      "store_user_session" => fn ->
        user_id = System.unique_integer()
        session_data = %{
          user_id: user_id,
          session_id: "sess_#{user_id}",
          csrf_token: Base.encode64(:crypto.strong_rand_bytes(32)),
          last_activity: DateTime.utc_now(),
          ip_address: "192.168.1.#{rem(user_id, 255)}"
        }
        Concord.put("session:#{user_id}", session_data, [ttl: 1800]) # 30 min TTL
      end,

      "track_page_view" => fn ->
        user_id = :rand.uniform(1000)
        page = "/page#{:rand.uniform(100)}"
        Concord.put("analytics:#{user_id}:pages:#{System.unique_integer()}", %{
          page: page,
          timestamp: DateTime.utc_now(),
          user_agent: "Mozilla/5.0..."
        }, [ttl: 86400]) # 24 hour TTL
      end,

      "rate_limit_check" => fn ->
        user_id = :rand.uniform(1000)
        key = "rate_limit:#{user_id}:#{DateTime.utc_now() |> DateTime.to_date()}"

        # Get current count
        current = case Concord.get(key) do
          {:ok, count} -> count
          {:error, :not_found} -> 0
        end

        # Increment and check against limit
        new_count = current + 1
        Concord.put(key, new_count, [ttl: 86400])
        new_count <= 100 # Assuming 100 requests per day limit
      end,

      "cache_api_response" => fn ->
        endpoint = "/api/v1/resource#{:rand.uniform(50)}"
        response = %{
          data: "api_response_data_#{System.unique_integer()}",
          cached_at: DateTime.utc_now(),
          expires_in: 300
        }
        Concord.put("cache:api:#{endpoint}", response, [ttl: 300]) # 5 min cache
      end
    }, "Web Application Operations")
  end

  def phoenix_session_store_scenario do
    IO.puts("\n🔥 Phoenix Session Store Scenario")
    IO.puts("=================================")

    # Simulate Phoenix using Concord as session store
    IO.puts("Simulating Phoenix session storage patterns...")

    benchee_run(%{
      "create_session" => fn ->
        session_id = Base.encode64(:crypto.strong_rand_bytes(24))
        session_data = %{
          user_id: System.unique_integer([:positive]),
          flash: %{"info" => "Welcome!"},
          locale: "en",
          timezone: "UTC"
        }
        Concord.put("phx_sess:#{session_id}", session_data, [ttl: 7200]) # 2 hours
      end,

      "load_session" => fn ->
        session_id = Base.encode64(:crypto.strong_rand_bytes(24))
        # Pre-create session
        Concord.put("phx_sess:#{session_id}", %{user_id: 123}, [ttl: 7200])
        # Load it
        Concord.get("phx_sess:#{session_id}")
      end,

      "update_session" => fn ->
        session_id = Base.encode64(:crypto.strong_rand_bytes(24))
        Concord.put("phx_sess:#{session_id}", %{user_id: 123}, [ttl: 7200])

        # Update with new data
        updated_data = %{
          user_id: 123,
          flash: %{"success" => "Profile updated"},
          last_activity: DateTime.utc_now()
        }
        Concord.put("phx_sess:#{session_id}", updated_data, [ttl: 7200])
      end,

      "cleanup_expired_sessions" => fn ->
        # Simulate cleanup by touching valid sessions
        session_id = Base.encode64(:crypto.strong_rand_bytes(24))
        Concord.put("phx_sess:#{session_id}", %{user_id: 123}, [ttl: 7200])
        Concord.touch("phx_sess:#{session_id}", 7200)
      end
    }, "Phoenix Session Store Operations")
  end

  def configuration_management_scenario do
    IO.puts("\n⚙️  Configuration Management Scenario")
    IO.puts("=====================================")

    # Simulate dynamic configuration management
    IO.puts("Simulating dynamic configuration updates...")

    # Pre-populate some configuration
    config_data = %{
      database: %{host: "localhost", port: 5432, pool_size: 10},
      features: %{new_ui: true, beta_features: false},
      limits: %{max_requests_per_minute: 1000, max_upload_size: 10_485_760}
    }
    Concord.put("config:app", config_data)

    benchee_run(%{
      "get_config_value" => fn ->
        case Concord.get("config:app") do
          {:ok, config} -> config[:database][:port]
          {:error, _} -> 5432
        end
      end,

      "update_feature_flag" => fn ->
        case Concord.get("config:app") do
          {:ok, config} ->
            updated_config = put_in(config, [:features, :beta_features], true)
            Concord.put("config:app", updated_config)
          {:error, _} -> :ok
        end
      end,

      "get_nested_config" => fn ->
        case Concord.get("config:app") do
          {:ok, config} ->
            {
              config[:database][:pool_size],
              config[:limits][:max_requests_per_minute],
              config[:features][:new_ui]
            }
          {:error, _} -> {10, 1000, false}
        end
      end,

      "cache_configuration" => fn ->
        # Simulate caching configuration in process dictionary
        case Concord.get("config:app") do
          {:ok, config} ->
            Process.put(:cached_config, config)
            config
          {:error, _} -> %{}
        end
      end
    }, "Configuration Management Operations")
  end

  def feature_flag_scenario do
    IO.puts("\n🚩 Feature Flag Scenario")
    IO.puts("=========================")

    # Simulate feature flag management system
    IO.puts("Simulating feature flag operations...")

    # Pre-populate feature flags
    feature_flags = %{
      "new_dashboard" => %{
        enabled: true,
        rollout_percentage: 100,
        user_ids: [],
        conditions: %{plan: ["premium", "enterprise"]}
      },
      "beta_search" => %{
        enabled: false,
        rollout_percentage: 20,
        user_ids: [123, 456, 789],
        conditions: %{beta: true}
      }
    }

    for {flag, data} <- feature_flags do
      Concord.put("flag:#{flag}", data)
    end

    benchee_run(%{
      "check_feature_flag" => fn ->
        flag = "new_dashboard"
        user_id = System.unique_integer([:positive])
        user_plan = if rem(user_id, 3) == 0, do: "premium", else: "basic"

        case Concord.get("flag:#{flag}") do
          {:ok, flag_data} ->
            enabled = flag_data.enabled and
                     (flag_data.rollout_percentage >= 50 or
                      user_id in flag_data.user_ids or
                      user_plan in flag_data.conditions.plan)
            enabled
          {:error, _} -> false
        end
      end,

      "enable_feature_for_user" => fn ->
        flag = "beta_search"
        user_id = System.unique_integer([:positive])

        case Concord.get("flag:#{flag}") do
          {:ok, flag_data} ->
            updated_users = [user_id | flag_data.user_ids] |> Enum.uniq()
            updated_flag = %{flag_data | user_ids: updated_users, enabled: true}
            Concord.put("flag:#{flag}", updated_flag)
          {:error, _} -> :ok
        end
      end,

      "bulk_flag_check" => fn ->
        flags = ["new_dashboard", "beta_search", "advanced_analytics", "real_time_sync"]
        user_id = System.unique_integer([:positive])

        for flag <- flags do
          case Concord.get("flag:#{flag}") do
            {:ok, flag_data} -> flag_data.enabled
            {:error, _} -> false
          end
        end
      end
    }, "Feature Flag Operations")
  end

  def caching_scenario do
    IO.puts("\n💾 Caching Scenario")
    IO.puts("===================")

    # Simulate application-level caching
    IO.puts("Simulating caching layer operations...")

    benchee_run(%{
      "cache_computation_result" => fn ->
        cache_key = "calc:result:#{:rand.uniform(100)}"
        result = %{
          value: :rand.uniform(1000),
          computed_at: DateTime.utc_now(),
          computation_time_ms: :rand.uniform(100)
        }
        Concord.put(cache_key, result, [ttl: 300]) # 5 minute cache
      end,

      "get_cached_result" => fn ->
        cache_key = "calc:result:#{:rand.uniform(100)}"
        case Concord.get(cache_key) do
          {:ok, cached} -> cached[:value]
          {:error, :not_found} ->
            # Simulate computation and cache result
            result = :rand.uniform(1000)
            Concord.put(cache_key, %{value: result, computed_at: DateTime.utc_now()}, [ttl: 300])
            result
        end
      end,

      "cache_invalidation" => fn ->
        pattern = "calc:result:*"
        # In real implementation, this would be more sophisticated
        # For now, simulate by touching with short TTL
        for i <- 1..10 do
          Concord.touch("calc:result:#{i}", 1)
        end
      end,

      "bulk_cache_operations" => fn ->
        operations = for i <- 1..50 do
          %{"key" => "bulk:cache:#{i}", "value" => "cached_value_#{i}", "ttl" => 600}
        end
        Concord.put_many(operations)
      end
    }, "Caching Operations")
  end

  def distributed_lock_scenario do
    IO.puts("\n🔒 Distributed Lock Scenario")
    IO.puts("=============================")

    # Simulate distributed locking using Concord
    IO.puts("Simulating distributed lock operations...")

    benchee_run(%{
      "acquire_lock" => fn ->
        lock_key = "lock:resource:#{System.unique_integer()}"
        lock_data = %{
          owner: self(),
          acquired_at: DateTime.utc_now(),
          expires_at: DateTime.add(DateTime.utc_now(), 30, :second)
        }
        Concord.put(lock_key, lock_data, [ttl: 30])
      end,

      "check_lock_status" => fn ->
        lock_key = "lock:resource:#{System.unique_integer()}"
        case Concord.get(lock_key) do
          {:ok, lock_data} ->
            expired = DateTime.compare(lock_data.expires_at, DateTime.utc_now()) == :lt
            not expired and lock_data.owner == self()
          {:error, :not_found} -> true # Lock available
        end
      end,

      "release_lock" => fn ->
        lock_key = "lock:resource:#{System.unique_integer()}"
        # Simulate lock acquisition
        Concord.put(lock_key, %{owner: self()}, [ttl: 30])
        # Release it
        Concord.delete(lock_key)
      end,

      "lock_renewal" => fn ->
        lock_key = "lock:resource:#{System.unique_integer()}"
        # Acquire lock
        Concord.put(lock_key, %{owner: self()}, [ttl: 30])
        # Renew it
        Concord.touch(lock_key, 60)
      end
    }, "Distributed Lock Operations")
  end

  def pubsub_state_scenario do
    IO.puts("\n📡 PubSub State Scenario")
    IO.puts("==========================")

    # Simulate PubSub state management
    IO.puts("Simulating PubSub state synchronization...")

    benchee_run(%{
      "store_subscriber_state" => fn ->
        topic = "events:user:#{System.unique_integer([:positive])}"
        subscriber = self()
        state = %{
          last_seen: System.unique_integer(),
          subscriber: subscriber,
          subscribed_at: DateTime.utc_now()
        }
        Concord.put("pubsub:#{topic}:#{subscriber}", state, [ttl: 3600])
      end,

      "broadcast_to_subscribers" => fn ->
        topic = "events:global"
        message_id = System.unique_integer()
        message = %{id: message_id, type: "notification", data: "Hello World"}

        # Store message for subscribers
        Concord.put("pubsub:#{topic}:msg:#{message_id}", message, [ttl: 300])

        # Update topic state
        case Concord.get("pubsub:#{topic}:state") do
          {:ok, state} ->
            updated_state = %{state | last_message_id: message_id, message_count: state.message_count + 1}
            Concord.put("pubsub:#{topic}:state", updated_state)
          {:error, :not_found} ->
            initial_state = %{last_message_id: message_id, message_count: 1}
            Concord.put("pubsub:#{topic}:state", initial_state)
        end
      end,

      "get_subscriber_state" => fn ->
        topic = "events:user:#{System.unique_integer([:positive])}"
        subscriber = self()

        case Concord.get("pubsub:#{topic}:#{subscriber}") do
          {:ok, state} -> state.last_seen
          {:error, :not_found} -> 0
        end
      end,

      "cleanup_expired_states" => fn ->
        # Simulate cleanup of expired subscriber states
        for i <- 1..20 do
          Concord.touch("pubsub:cleanup:test:#{i}", 1)
        end
      end
    }, "PubSub State Operations")
  end

  defp benchee_run(jobs, description) do
    IO.puts("\n#{description}:")

    try do
      if Code.ensure_loaded?(Benchee) do
        Benchee.run(%{
          time: 3,
          memory_time: 1,
          print: [configuration: false],
          inputs: %{
            "Embedded Scenario" => jobs
          }
        })
      else
        simple_benchmark(jobs)
      end
    rescue
      _ -> simple_benchmark(jobs)
    end
  end

  defp simple_benchmark(jobs) do
    for {name, fun} <- jobs do
      # Warm up
      fun.()

      # Measure
      measurements = for _i <- 1..100 do
        {time_us, _result} = :timer.tc(fun)
        time_us
      end

      avg_time = Enum.sum(measurements) / length(measurements)
      min_time = Enum.min(measurements)
      max_time = Enum.max(measurements)
      ops_per_sec = Float.round(1_000_000 / avg_time, 2)

      IO.puts("  #{name}:")
      IO.puts("    Average: #{Float.round(avg_time, 2)}μs (#{ops_per_sec} ops/sec)")
      IO.puts("    Range: #{min_time}μs - #{max_time}μs")
    end
  end
end