defmodule Concord.TursoConditionalPutValidationTest do
  use ExUnit.Case, async: false

  alias Concord.{CommandSchema, Compression, Turso, Validation}
  alias Concord.Engine.Turso, as: TursoEngine
  alias Concord.Turso.ConditionalPut

  setup do
    keys = [:kv, :txn, :compression, :max_batch_size, :max_command_bytes]
    original = Map.new(keys, &{&1, Application.fetch_env(:concord, &1)})

    on_exit(fn ->
      for {key, value} <- original do
        case value do
          {:ok, setting} -> Application.put_env(:concord, key, setting)
          :error -> Application.delete_env(:concord, key)
        end
      end
    end)

    Application.put_env(:concord, :compression, enabled: false)
    :ok
  end

  test "500 total pairs fit independently of generic transaction operation and byte ceilings" do
    value = :binary.copy("x", 2_000_000)
    puts = [{"metadata", value} | for(n <- 1..499, do: {"turns/#{n}", n})]
    Application.put_env(:concord, :txn, max_success_ops: 0, max_txn_bytes: 64)

    assert {:ok, {:put_many_if, ^puts, []}} = ConditionalPut.prepare(puts, compress: false)

    assert {:error, {:invalid_txn, :too_many_success_ops}} =
             Validation.validate_txn_spec(%{success: [{:put, "metadata", value, %{}}]})
  end

  test "501 pairs are rejected even when configuration admits prefix replacement's extra pair" do
    puts = for n <- 1..501, do: {"turns/#{n}", n}

    for cap <- [501, 1_000] do
      Application.put_env(:concord, :max_batch_size, cap)
      assert {:error, :batch_too_large} = ConditionalPut.validate(puts, [])
      assert {:error, :batch_too_large} = Turso.put_many_if(puts)
    end

    Application.delete_env(:concord, :max_batch_size)
    assert {:error, :batch_too_large} = ConditionalPut.validate(puts, [])
    assert :ok = ConditionalPut.validate(Enum.take(puts, 500), [])
  end

  test "lower and invalid configured item limits fail closed" do
    Application.put_env(:concord, :max_batch_size, 1)
    assert :ok = ConditionalPut.validate([{"a", 1}], [])
    assert {:error, :batch_too_large} = ConditionalPut.validate([{"a", 1}, {"b", 2}], [])

    for cap <- [0, -1, nil, :invalid] do
      Application.put_env(:concord, :max_batch_size, cap)
      assert {:error, :batch_too_large} = ConditionalPut.validate([{"a", 1}], [])
      assert :ok = ConditionalPut.validate([], [])
    end
  end

  test "duplicate, malformed and improper pairs return structured errors" do
    assert {:error, :duplicate_key} = ConditionalPut.validate([{"a", 1}, {"a", 2}], [])

    for malformed <- [:invalid, %{}, [{"a", 1, 10}], [{:put, "a", 1, %{}}], [{"a", 1} | :bad]] do
      assert {:error, :invalid_operation_format} = ConditionalPut.validate(malformed, [])
    end

    for {key, reason} <- [
          {"", :empty_key},
          {:key, :invalid_key},
          {:binary.copy("k", 4_097), :key_too_large}
        ] do
      assert {:error, ^reason} = ConditionalPut.validate([{key, 1}], [])
    end
  end

  test "key caps can lower but cannot raise the immutable boundary" do
    Application.put_env(:concord, :kv, max_key_bytes: 2)
    assert :ok = ConditionalPut.validate([{"ab", 1}], [])
    assert {:error, :key_too_large} = ConditionalPut.validate([{"abc", 1}], [])
    Application.put_env(:concord, :kv, max_key_bytes: 8_192)
    assert {:error, :key_too_large} = ConditionalPut.validate([{:binary.copy("k", 4_097), 1}], [])
  end

  test "nondeterministic values and hidden compressed values are rejected despite engine overrides" do
    Application.put_env(:concord, :compression, enabled: false, threshold_bytes: 0)

    for {value, reason} <- [
          {self(), :pid_in_spec},
          {make_ref(), :ref_in_spec},
          {fn -> :unsafe end, :function_in_spec}
        ] do
      assert {:error, ^reason} = Turso.put_many_if([{"a", %{nested: value}}], engine: :local)
      compressed = Compression.compress(%{nested: value}, force: true)
      assert {:error, ^reason} = ConditionalPut.validate([{"a", compressed}], [])
    end

    assert {:error, :invalid_compressed_value} =
             ConditionalPut.validate([{"a", {:compressed, :zlib, <<1, 2, 3>>}}], [])
  end

  test "16 MiB logical value cap includes encoding overhead and cannot be raised or compressed away" do
    at_limit = :binary.copy("x", CommandSchema.max_value_bytes() - 6)
    assert :ok = ConditionalPut.validate([{"a", at_limit}], [])
    too_large = at_limit <> "x"
    Application.put_env(:concord, :kv, max_value_bytes: CommandSchema.max_value_bytes() * 2)
    assert {:error, :value_too_large} = ConditionalPut.prepare([{"a", too_large}], compress: true)
    compressed = Compression.compress(too_large, force: true)
    assert {:error, :value_too_large} = ConditionalPut.validate([{"a", compressed}], [])
  end

  test "configured value limits apply to logical and encoded values" do
    Application.put_env(:concord, :kv, max_value_bytes: 128)

    assert {:error, :value_too_large} =
             ConditionalPut.prepare([{"a", :binary.copy("x", 128)}], compress: true)

    bloated = {:compressed, :none, :erlang.term_to_binary(:ok) <> :binary.copy("x", 128)}
    assert {:error, :value_too_large} = ConditionalPut.validate([{"a", bloated}], [])
    Application.put_env(:concord, :compression, enabled: false, threshold_bytes: 0)
    Application.put_env(:concord, :kv, max_value_bytes: :erlang.external_size(:ok))
    assert :ok = ConditionalPut.validate([{"a", :ok}], [])
    assert {:error, :value_too_large} = ConditionalPut.prepare([{"a", :ok}], compress: true)
  end

  test "actual command boundary includes exact keys and predicates" do
    puts = [{"a", "payload"}]
    compares = [{:mod_revision, "metadata", :==, 17}]
    command = {:put_many_if, puts, compares}
    actual_size = :erlang.external_size(command)
    Application.put_env(:concord, :max_command_bytes, actual_size)
    assert :ok = ConditionalPut.validate(puts, compares)
    Application.put_env(:concord, :max_command_bytes, actual_size - 1)

    assert {:error, {:invalid_command, :command_too_large}} =
             ConditionalPut.validate(puts, compares)

    assert :ok = ConditionalPut.validate(puts, [])
  end

  test "64 MiB command cap cannot be widened or bypassed by compressed values" do
    value = :binary.copy("x", CommandSchema.max_value_bytes() - 6)
    puts = for n <- 1..4, do: {"turns/#{n}", value}
    Application.put_env(:concord, :max_command_bytes, CommandSchema.max_command_bytes() * 2)
    assert {:error, {:invalid_command, :command_too_large}} = ConditionalPut.validate(puts, [])
    compressed = Compression.compress(value, force: true)
    puts = for n <- 1..4, do: {"turns/#{n}", compressed}
    assert :erlang.external_size({:put_many_if, puts, []}) < 100_000
    assert {:error, {:invalid_command, :command_too_large}} = ConditionalPut.validate(puts, [])
  end

  test "preparation supports compression and validates the full encoded command again" do
    value = %{text: :binary.copy("x", 8_192)}
    compares = [{:exists, "metadata", :==, true}]

    assert {:ok, {:put_many_if, [{"a", compressed}], ^compares}} =
             ConditionalPut.prepare([{"a", value}], compress: true, compare: compares)

    assert {:compressed, :zlib, _} = compressed
    assert {:ok, ^value} = Compression.safe_decompress(compressed)
    assert {:error, :invalid_compress} = ConditionalPut.prepare([], compress: :invalid)

    Application.put_env(:concord, :compression, enabled: false, threshold_bytes: 0)

    Application.put_env(
      :concord,
      :max_command_bytes,
      :erlang.external_size({:put_many_if, [{"a", :ok}], []})
    )

    assert {:ok, _} = ConditionalPut.prepare([{"a", :ok}], compress: false)

    assert {:error, {:invalid_command, :command_too_large}} =
             ConditionalPut.prepare([{"a", :ok}], compress: true)
  end

  test "predicates retain transaction grammar, compare count and predicate byte limits" do
    compares = [{:exists, "metadata", :==, true}, {:field, "metadata", [:title], :!=, nil}]
    assert :ok = ConditionalPut.validate([], compares)

    assert {:error, {:invalid_txn, :unsupported_compare_field}} =
             ConditionalPut.validate([], [{:unknown, "metadata", :==, true}])

    assert {:error, {:invalid_txn, :too_many_compares}} =
             ConditionalPut.validate([], List.duplicate({:exists, "metadata", :==, true}, 65))

    Application.put_env(:concord, :txn, max_compare_ops: 1)
    assert {:error, {:invalid_txn, :too_many_compares}} = ConditionalPut.validate([], compares)
    Application.put_env(:concord, :txn, max_txn_bytes: 64)

    assert {:error, {:invalid_txn, :spec_too_large}} =
             ConditionalPut.validate([], [{:value, "metadata", :==, :binary.copy("x", 100)}])
  end

  test "malformed and improper predicate collections return errors without raising" do
    for malformed <- [:invalid, %{}, [{:exists, "metadata", :==, true} | :invalid]] do
      assert {:error, {:invalid_txn, :invalid_spec}} = ConditionalPut.validate([], malformed)
    end

    assert {:error, {:invalid_txn, :invalid_field_path}} =
             ConditionalPut.validate([], [{:field, "metadata", [:nested | :bad], :==, true}])

    assert {:error, :pid_in_spec} =
             ConditionalPut.validate([], [{:value, "metadata", :==, self()}])
  end

  test "expired preparation and dispatch budgets are preserved and direct dispatch validates" do
    expired = System.monotonic_time(:millisecond) - 1
    assert {:error, :timeout} = Turso.put_many_if([], timeout: 0)

    assert {:error, :timeout} =
             ConditionalPut.prepare(:invalid, deadline: expired, timeout: :infinity)

    assert {:error, :timeout} =
             TursoEngine.command({:put_many_if, [], []}, deadline: expired, timeout: :infinity)

    assert {:error, :duplicate_key} =
             TursoEngine.command({:put_many_if, [{"a", 1}, {"a", 2}], []})

    assert {:ok, {:put_many_if, [], []}} = ConditionalPut.prepare([], timeout: :infinity)
  end
end
