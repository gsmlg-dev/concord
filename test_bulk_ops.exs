# Quick test to verify bulk operations are working
Application.ensure_all_started(:concord)
:timer.sleep(2000)

IO.puts("Testing Concord bulk operations...")

# Test basic bulk operations
test_ops = [{"key1", "value1"}, {"key2", "value2"}, {"key3", "value3"}]

IO.puts("Testing put_many...")
case Concord.put_many(test_ops) do
  :ok -> IO.puts("✅ put_many succeeded")
  {:error, reason} -> IO.puts("❌ put_many failed: #{inspect(reason)}")
end

IO.puts("Testing get_many...")
case Concord.get_many(["key1", "key2", "key3"]) do
  {:ok, results} -> IO.puts("✅ get_many succeeded: #{inspect(results)}")
  {:error, reason} -> IO.puts("❌ get_many failed: #{inspect(reason)}")
end

IO.puts("Testing delete_many...")
case Concord.delete_many(["key1", "key2", "key3"]) do
  :ok -> IO.puts("✅ delete_many succeeded")
  {:error, reason} -> IO.puts("❌ delete_many failed: #{inspect(reason)}")
end

IO.puts("Bulk operations test completed!")