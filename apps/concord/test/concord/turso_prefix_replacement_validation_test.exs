defmodule Concord.TursoPrefixReplacementValidationTest do
  use ExUnit.Case, async: false

  alias Concord.{CommandSchema, Compression, Turso, Validation}
  alias Concord.Turso.PrefixReplacement

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

  test "prepares empty replacement and related metadata puts without transaction operation limits" do
    assert {:ok, {:replace_prefix, "turns/", [], []}} =
             PrefixReplacement.prepare("turns/", [], [])

    puts = for number <- 1..500, do: {"turns/#{number}", number}

    assert {:ok, {:replace_prefix, "turns/", ^puts, []}} =
             PrefixReplacement.prepare("turns/", puts, [])

    puts = [{"turns/first", "transcript"}, {"session/metadata", %{title: "Updated"}}]
    compares = [{:mod_revision, "session/metadata", :==, 3}]

    assert {:ok, {:replace_prefix, "turns/", ^puts, ^compares}} =
             PrefixReplacement.prepare("turns/", puts, compare: compares)
  end

  test "replacement values do not consume generic transaction byte or operation ceilings" do
    value = :binary.copy("x", 2_000_000)
    Application.put_env(:concord, :txn, max_success_ops: 0, max_txn_bytes: 64)
    assert :ok = PrefixReplacement.validate("turns/", [{"turns/first", value}], [])

    assert {:error, {:invalid_txn, :too_many_success_ops}} =
             Validation.validate_txn_spec(%{success: [{:put, "turns/first", value, %{}}]})
  end

  test "rejects empty, nonbinary and oversized prefix or put keys" do
    assert {:error, :empty_key} = PrefixReplacement.validate("", [], [])
    assert {:error, :invalid_key} = PrefixReplacement.validate(:prefix, [], [])

    assert {:error, :key_too_large} =
             PrefixReplacement.validate(:binary.copy("p", 4_097), [], [])

    for {key, reason} <- [
          {"", :empty_key},
          {:bad, :invalid_key},
          {:binary.copy("k", 4_097), :key_too_large}
        ] do
      assert {:error, ^reason} = PrefixReplacement.validate("p/", [{key, :value}], [])
    end
  end

  test "configured key caps can lower but cannot widen the immutable boundary" do
    Application.put_env(:concord, :kv, max_key_bytes: 2)
    assert :ok = PrefixReplacement.validate("p/", [{"p/", :value}], [])
    assert {:error, :key_too_large} = PrefixReplacement.validate("p/", [{"p/a", :value}], [])
    Application.put_env(:concord, :kv, max_key_bytes: 8_192)

    assert {:error, :key_too_large} =
             PrefixReplacement.validate(:binary.copy("p", 4_097), [], [])
  end

  test "rejects duplicate, malformed and improper put collections without raising" do
    assert {:error, :duplicate_key} =
             PrefixReplacement.validate("p/", [{"p/a", 1}, {"p/a", 2}], [])

    for malformed <- [
          :invalid,
          %{},
          [{"p/a", 1, 10}],
          [{:put, "p/a", 1, %{}}],
          [{"p/a", 1} | :invalid],
          [{"p/a", 1}, :invalid]
        ] do
      assert {:error, :invalid_operation_format} = PrefixReplacement.validate("p/", malformed, [])
    end
  end

  test "enforces the immutable batch cap and configured lower caps" do
    puts = for number <- 1..501, do: {"p/#{number}", number}
    assert {:error, :batch_too_large} = PrefixReplacement.validate("p/", puts, [])
    Application.put_env(:concord, :max_batch_size, 1_000)
    assert {:error, :batch_too_large} = PrefixReplacement.validate("p/", puts, [])
    Application.put_env(:concord, :max_batch_size, 1)
    assert {:error, :batch_too_large} = PrefixReplacement.validate("p/", Enum.take(puts, 2), [])
    assert :ok = PrefixReplacement.validate("p/", Enum.take(puts, 1), [])
  end

  test "rejects nondeterministic values even when a caller requests the Local engine" do
    for {value, reason} <- [
          {self(), :pid_in_spec},
          {make_ref(), :ref_in_spec},
          {fn -> :unsafe end, :function_in_spec}
        ] do
      assert {:error, ^reason} =
               PrefixReplacement.prepare("p/", [{"p/a", %{nested: value}}],
                 engine: :local,
                 compress: true
               )

      assert {:error, ^reason} =
               Turso.replace_prefix("p/", [{"p/a", value}], engine: :local)
    end
  end

  test "validates logical values before compression and revalidates supplied compression envelopes" do
    too_large = :binary.copy("x", CommandSchema.max_value_bytes() - 5)

    assert {:error, :value_too_large} =
             PrefixReplacement.prepare("p/", [{"p/a", too_large}], compress: true)

    compressed = Compression.compress(too_large, force: true)

    assert {:error, :value_too_large} =
             PrefixReplacement.validate("p/", [{"p/a", compressed}], [])

    assert {:error, :invalid_compressed_value} =
             PrefixReplacement.validate("p/", [{"p/a", {:compressed, :zlib, <<1, 2, 3>>}}], [])

    unsafe = Compression.compress(%{pid: self()}, force: true)
    assert {:error, :pid_in_spec} = PrefixReplacement.validate("p/", [{"p/a", unsafe}], [])
  end

  test "supports ordinary compression while retaining original keys and predicates" do
    value = %{text: :binary.copy("x", 8_192)}
    compares = [{:exists, "owner", :==, true}]

    assert {:ok, {:replace_prefix, "p/", [{"p/a", compressed}], ^compares}} =
             PrefixReplacement.prepare("p/", [{"p/a", value}], compress: true, compare: compares)

    assert {:compressed, :zlib, _} = compressed
    assert {:ok, ^value} = Compression.safe_decompress(compressed)
    assert {:error, :invalid_compress} = PrefixReplacement.prepare("p/", [], compress: :invalid)
  end

  test "applies configured value caps before and after encoded preparation" do
    Application.put_env(:concord, :kv, max_value_bytes: 128)

    assert {:error, :value_too_large} =
             PrefixReplacement.prepare("p/", [{"p/a", :binary.copy("x", 128)}], compress: true)

    # This logical value fits 128 bytes, but a deliberately bloated encoded
    # compression envelope must also obey the raw value cap.
    bloated = {:compressed, :none, :erlang.term_to_binary(:ok) <> :binary.copy("x", 128)}
    assert {:error, :value_too_large} = PrefixReplacement.validate("p/", [{"p/a", bloated}], [])
    Application.put_env(:concord, :kv, max_value_bytes: CommandSchema.max_value_bytes() * 2)

    assert {:error, :value_too_large} =
             PrefixReplacement.validate(
               "p/",
               [{"p/a", :binary.copy("x", CommandSchema.max_value_bytes())}],
               []
             )
  end

  test "uses the actual encoded command boundary including prefix, keys and predicates" do
    puts = [{"p/a", "payload"}]
    compares = [{:mod_revision, "owner", :==, 17}]
    command = {:replace_prefix, "p/", puts, compares}
    actual_size = :erlang.external_size(command)
    Application.put_env(:concord, :max_command_bytes, actual_size)
    assert :ok = PrefixReplacement.validate("p/", puts, compares)
    Application.put_env(:concord, :max_command_bytes, actual_size - 1)

    assert {:error, {:invalid_command, :command_too_large}} =
             PrefixReplacement.validate("p/", puts, compares)
  end

  test "the 64 MiB command limit cannot be widened or bypassed by compressed values" do
    value = :binary.copy("x", CommandSchema.max_value_bytes() - 6)
    assert :ok = Validation.validate_value(value, engine: :turso)
    puts = for number <- 1..4, do: {"p/#{number}", value}
    Application.put_env(:concord, :max_command_bytes, CommandSchema.max_command_bytes() * 2)

    assert {:error, {:invalid_command, :command_too_large}} =
             PrefixReplacement.validate("p/", puts, [])

    compressed = Compression.compress(value, force: true)
    puts = for number <- 1..4, do: {"p/#{number}", compressed}
    assert :erlang.external_size({:replace_prefix, "p/", puts, []}) < 100_000

    assert {:error, {:invalid_command, :command_too_large}} =
             PrefixReplacement.validate("p/", puts, [])
  end

  test "retains transaction predicate grammar, counts and configured predicate byte limits" do
    compares = [{:exists, "owner", :==, true}, {:field, "owner", [:nested, "title"], :!=, nil}]
    assert :ok = PrefixReplacement.validate("p/", [], compares)

    assert {:error, {:invalid_txn, :unsupported_compare_field}} =
             PrefixReplacement.validate("p/", [], [{:unknown, "owner", :==, true}])

    assert {:error, {:invalid_txn, :too_many_compares}} =
             PrefixReplacement.validate(
               "p/",
               [],
               List.duplicate({:exists, "owner", :==, true}, 65)
             )

    Application.put_env(:concord, :txn, max_compare_ops: 1)

    assert {:error, {:invalid_txn, :too_many_compares}} =
             PrefixReplacement.validate("p/", [], compares)

    Application.put_env(:concord, :txn, max_txn_bytes: 64)

    assert {:error, {:invalid_txn, :spec_too_large}} =
             PrefixReplacement.validate("p/", [], [{:value, "owner", :==, :binary.copy("x", 100)}])
  end

  test "malformed and improper predicate collections return structured validation errors" do
    for malformed <- [:invalid, %{}, [{:exists, "owner", :==, true} | :invalid]] do
      assert {:error, {:invalid_txn, :invalid_spec}} =
               PrefixReplacement.validate("p/", [], malformed)
    end

    assert {:error, {:invalid_txn, :invalid_field_path}} =
             PrefixReplacement.validate("p/", [], [{:field, "owner", [:nested | :bad], :==, true}])

    assert {:error, :pid_in_spec} =
             PrefixReplacement.validate("p/", [], [{:value, "owner", :==, %{pid: self()}}])
  end

  test "expired caller budget wins before preparation and is never replaced by a new timeout" do
    expired = System.monotonic_time(:millisecond) - 1
    assert {:error, :timeout} = PrefixReplacement.prepare("p/", [], timeout: 0)

    assert {:error, :timeout} =
             PrefixReplacement.prepare("", :invalid, deadline: expired, timeout: :infinity)

    assert {:error, :timeout} =
             Turso.replace_prefix("", :invalid, deadline: expired, timeout: :infinity)

    assert {:ok, {:replace_prefix, "p/", [], []}} =
             PrefixReplacement.prepare("p/", [], timeout: :infinity)
  end
end
