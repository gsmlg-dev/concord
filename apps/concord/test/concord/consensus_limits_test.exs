defmodule Concord.ConsensusLimitsTest do
  use ExUnit.Case, async: false

  alias Concord.{CommandSchema, Compression, KV, Txn, Validation}

  @configured_keys [:kv, :txn, :max_batch_size, :max_command_bytes]

  setup do
    original = Map.new(@configured_keys, &{&1, Application.get_env(:concord, &1)})

    on_exit(fn ->
      Enum.each(original, fn
        {key, nil} -> Application.delete_env(:concord, key)
        {key, value} -> Application.put_env(:concord, key, value)
      end)
    end)

    :ok
  end

  test "operator limits cannot widen the immutable v1 protocol maxima" do
    Application.put_env(:concord, :max_batch_size, CommandSchema.max_batch_size() + 100)
    Application.put_env(:concord, :max_command_bytes, CommandSchema.max_command_bytes() + 1)

    Application.put_env(:concord, :kv,
      max_key_bytes: CommandSchema.max_key_bytes() + 100,
      max_value_bytes: CommandSchema.max_value_bytes() + 1
    )

    Application.put_env(:concord, :txn,
      max_compare_ops: CommandSchema.max_txn_compares() + 10,
      max_success_ops: CommandSchema.max_txn_operations() + 10,
      max_failure_ops: CommandSchema.max_txn_operations() + 10,
      max_txn_bytes: CommandSchema.max_txn_bytes() + 1,
      max_range_limit: CommandSchema.max_txn_range_limit() + 1
    )

    assert {:error, :key_too_large} =
             Validation.validate_key(String.duplicate("k", CommandSchema.max_key_bytes() + 1))

    operations =
      for index <- 1..(CommandSchema.max_batch_size() + 1), do: {"k#{index}", index}

    assert {:error, :batch_too_large} = Concord.put_many(operations)

    compares =
      for index <- 1..(CommandSchema.max_txn_compares() + 1),
          do: {:exists, "k#{index}", :==, true}

    assert {:error, {:invalid_txn, :too_many_compares}} =
             Validation.validate_txn_spec(%{compare: compares})

    oversized_spec = %{
      success: [{:put, "key", String.duplicate("x", CommandSchema.max_txn_bytes()), %{}}]
    }

    assert {:error, {:invalid_txn, :spec_too_large}} =
             Validation.validate_txn_spec(oversized_spec)
  end

  test "logical value admission is independent of compression choice" do
    Application.put_env(:concord, :kv,
      max_key_bytes: CommandSchema.max_key_bytes(),
      max_value_bytes: 64
    )

    value = String.duplicate("x", 64)

    assert :erlang.external_size(value) > 64
    assert {:error, :value_too_large} = Concord.put("auto", value)
    assert {:error, :value_too_large} = Concord.put("forced", value, compress: true)
    assert {:error, :value_too_large} = Concord.put("plain", value, compress: false)
  end

  test "transaction size is measured from logical values, not compressed wire bytes" do
    value = String.duplicate("x", CommandSchema.max_txn_bytes())

    assert {:error, {:invalid_txn, :spec_too_large}} =
             KV.create("plain", value, compress: false)

    assert {:error, {:invalid_txn, :spec_too_large}} =
             KV.create("compressed", value, compress: true)
  end

  test "transaction admission includes the caller idempotency key" do
    spec = %{compare: [], success: [], failure: []}
    idempotency_key = String.duplicate("i", 128)
    combined = Map.put(spec, :idempotency_key, idempotency_key)

    assert {:ok, base_size} =
             CommandSchema.raw_external_size_v1(spec, CommandSchema.max_txn_bytes())

    assert {:ok, combined_size} =
             CommandSchema.raw_external_size_v1(combined, CommandSchema.max_txn_bytes())

    assert combined_size > base_size
    Application.put_env(:concord, :txn, max_txn_bytes: base_size)

    assert {:error, {:invalid_txn, :spec_too_large}} =
             Txn.commit(spec, idempotency_key: idempotency_key)
  end

  test "v1 replay uses fixed limits and safety independent of local admission settings" do
    Application.put_env(:concord, :max_command_bytes, 64)

    Application.put_env(:concord, :kv,
      max_key_bytes: CommandSchema.max_key_bytes(),
      max_value_bytes: 64
    )

    value = String.duplicate("x", 128)
    compressed = Compression.compress(value, force: true, threshold: 0)

    assert {:error, :value_too_large} = Validation.validate_value(value)

    assert {:error, {:invalid_command, :command_too_large}} =
             Validation.validate_command_size({:put, "key", value, %{}})

    assert :ok = CommandSchema.validate_replay(1, {:put, "plain", value, %{}})
    assert :ok = CommandSchema.validate_replay(1, {:put, "compressed", compressed, %{}})

    assert {:error, {:invalid_command, :function_in_spec}} =
             CommandSchema.validate_replay(1, {:put, "unsafe", fn -> :unsafe end, %{}})

    assert {:error, {:invalid_command, :invalid_compressed_value}} =
             CommandSchema.validate_replay(
               1,
               {:put, "malformed", {:compressed, :zlib, <<1, 2, 3>>}, %{}}
             )
  end

  test "field compares participate in value sizing without crashing" do
    command =
      {:txn,
       %{
         compare: [{:field, "key", [:profile, :active], :==, true}],
         success: [],
         failure: []
       }}

    assert :ok = CommandSchema.validate_replay(1, command)
  end

  test "v1 rejects the same oversized logical value compressed or plain" do
    value = String.duplicate("x", CommandSchema.max_value_bytes())
    compressed = Compression.compress(value, force: true, threshold: 0)

    assert :erlang.external_size(value) > CommandSchema.max_value_bytes()

    for representation <- [value, compressed] do
      assert {:error, {:invalid_command, :value_too_large}} =
               CommandSchema.validate_replay(1, {:put, "key", representation, %{}})
    end
  end

  test "aggregate logical command limit covers bulk puts and backup restores" do
    shared_value = String.duplicate("x", 1_024 * 1_024)
    compressed = Compression.compress(shared_value, force: true, threshold: 0)

    for representation <- [shared_value, compressed] do
      entries = for index <- 1..65, do: {"k#{index}", representation}
      puts = Enum.map(entries, fn {key, value} -> {key, value, nil} end)
      backup = %{version: 2, kv_data: entries, indexes: %{}}

      assert {:error, {:invalid_command, :command_too_large}} =
               CommandSchema.validate_replay(1, {:put_many, puts})

      assert {:error, {:invalid_command, :command_too_large}} =
               CommandSchema.validate_replay(1, {:restore_backup, backup})
    end
  end

  test "bounded size accounting short-circuits raw and expanded representations" do
    value = String.duplicate("x", 1_024)
    compressed = Compression.compress(value, force: true, threshold: 0)
    command = {:put_many, for(index <- 1..10, do: {"k#{index}", compressed, nil})}

    assert {:ok, _raw_size} = CommandSchema.raw_external_size_v1(command, 2_048)
    assert {:error, :size_limit} = CommandSchema.logical_external_size_v1(command, 2_048)

    tiny = Compression.compress(:ok, force: true, threshold: 0)
    assert {:ok, _logical_size} = CommandSchema.logical_external_size_v1(tiny, 16)
    assert {:error, :size_limit} = CommandSchema.raw_external_size_v1(tiny, 16)
  end

  test "invalid admission cap settings fail closed" do
    Application.put_env(:concord, :max_command_bytes, "64")

    Application.put_env(:concord, :kv,
      max_key_bytes: CommandSchema.max_key_bytes(),
      max_value_bytes: -1
    )

    Application.put_env(:concord, :txn, max_compare_ops: "64")

    assert {:error, :value_too_large} = Validation.validate_value(:ok)

    assert {:error, {:invalid_command, :command_too_large}} =
             Validation.validate_command_size({:put, "key", :ok, %{}})

    assert {:error, {:invalid_txn, :too_many_compares}} =
             Validation.validate_txn_spec(%{compare: [{:exists, "key", :==, true}]})
  end

  test "compressed map keys cannot collide during logical size expansion" do
    compressed_key = Compression.compress(:key, force: true, threshold: 0)
    value = %{:key => "plain", compressed_key => "compressed"}

    assert {:error, {:invalid_command, :invalid_compressed_value}} =
             CommandSchema.validate_replay(1, {:put, "key", value, %{}})

    assert {:error, :invalid_compressed_value} = Validation.validate_value(value)
  end
end
