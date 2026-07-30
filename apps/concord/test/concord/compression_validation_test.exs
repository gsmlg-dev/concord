defmodule Concord.CompressionValidationTest do
  use ExUnit.Case, async: true

  alias Concord.{CommandEnvelope, Compression, KV, Validation}
  alias Concord.Engine.VSR.StateMachine, as: VSRStateMachine
  alias Concord.StateMachine.Core
  alias ViewstampedReplication.ApplyMetadata

  describe "compressed value validation" do
    test "accepts and safely decodes legitimate zlib, gzip, and uncompressed envelopes" do
      value = %{name: "concord", nested: [1, 2, %{enabled: true}]}

      Enum.each([:zlib, :gzip, :none], fn algorithm ->
        compressed =
          Compression.compress(value, force: true, threshold: 0, algorithm: algorithm)

        assert {:ok, ^value} = Compression.safe_decompress(compressed)
        assert ^value = Compression.decompress(compressed)
        assert :ok = Validation.validate_term(compressed)
      end)
    end

    test "rejects forbidden logical terms hidden inside compression" do
      unsafe_values = [
        {fn -> :unsafe end, :function_in_spec},
        {self(), :pid_in_spec},
        {make_ref(), :ref_in_spec}
      ]

      Enum.each([:zlib, :gzip, :none], fn algorithm ->
        Enum.each(unsafe_values, fn {value, reason} ->
          compressed =
            Compression.compress(%{nested: value},
              force: true,
              threshold: 0,
              algorithm: algorithm
            )

          assert {:error, ^reason} = Validation.validate_term(compressed)
        end)
      end)
    end

    test "rejects a port hidden inside compression" do
      port = Port.open({:spawn_executable, System.find_executable("cat")}, [:binary])

      try do
        compressed = Compression.compress(port, force: true, threshold: 0)
        assert {:error, :port_in_spec} = Validation.validate_term(compressed)
      after
        Port.close(port)
      end
    end

    test "uses one stable error for malformed and unknown compression envelopes" do
      {:compressed, :zlib, valid_payload} =
        Compression.compress(:valid, force: true, threshold: 0)

      malformed_values = [
        {:compressed, :zlib, <<1, 2, 3>>},
        {:compressed, :gzip, <<1, 2, 3>>},
        {:compressed, :zlib, :zlib.compress(:erlang.term_to_binary(:valid) <> "hidden")},
        {:compressed, :unknown, valid_payload},
        {:compressed, :zlib, :not_a_binary},
        {:compressed},
        {:compressed, :zlib, valid_payload, :extra}
      ]

      Enum.each(malformed_values, fn value ->
        assert {:error, :invalid_compressed_value} = Validation.validate_term(value)
      end)

      assert {:error, :invalid_compressed_value} =
               Compression.safe_decompress({:compressed, :unknown, valid_payload})
    end

    test "external-term decoding is independent of prior atom-table state" do
      atom_name = "concord_compressed_atom_#{System.unique_integer([:positive])}"
      assert_raise ArgumentError, fn -> String.to_existing_atom(atom_name) end

      external_term = <<131, 100, byte_size(atom_name)::16, atom_name::binary>>
      compressed = {:compressed, :zlib, :zlib.compress(external_term)}

      operation =
        CommandEnvelope.wrap(1_000, {:put, "atom-value", compressed, %{}})

      assert {%{revision: 1}, first_state} =
               VSRStateMachine.apply(metadata(1), operation, Core.init())

      assert {:ok, stored_value} =
               Core.query({:get, "atom-value"}, first_state, %{timestamp_ms: 1_000})

      decoded_atom = Compression.decompress(stored_value)
      assert Atom.to_string(decoded_atom) == atom_name
      assert String.to_existing_atom(atom_name) == decoded_atom

      # The same command bytes apply identically after the atom exists.
      assert {%{revision: 1}, second_state} =
               VSRStateMachine.apply(metadata(1), operation, Core.init())

      assert first_state == second_state
      assert {:ok, ^decoded_atom} = Compression.safe_decompress(compressed)
      assert :ok = Validation.validate_term(compressed)
    end

    test "rejects expanded values over the fixed admission limit for every algorithm" do
      value = String.duplicate("x", Compression.max_decompressed_bytes())

      Enum.each([:zlib, :gzip, :none], fn algorithm ->
        compressed =
          Compression.compress(value,
            force: true,
            threshold: 0,
            algorithm: algorithm
          )

        assert {:error, :invalid_compressed_value} = Compression.safe_decompress(compressed)
        assert {:error, :invalid_compressed_value} = Validation.validate_term(compressed)
      end)
    end

    test "rejects a nested compressed ETF stream that could bypass the outer limit" do
      nested_etf = :erlang.term_to_binary(String.duplicate("x", 100_000), compressed: 9)
      envelope = {:compressed, :none, nested_etf}

      assert {:error, :invalid_compressed_value} = Compression.safe_decompress(envelope)
      assert {:error, :invalid_compressed_value} = Validation.validate_term(envelope)
    end

    test "legacy reads retain access to values larger than the new admission limit" do
      value = String.duplicate("x", Compression.max_decompressed_bytes())
      compressed = Compression.compress(value, force: true, threshold: 0, algorithm: :zlib)

      assert {:error, :invalid_compressed_value} = Compression.safe_decompress(compressed)
      assert ^value = Compression.decompress(compressed)
    end

    test "version-zero replay preserves unknown-tag raw ETF decoding" do
      value = %{legacy: "value"}
      legacy_envelope = {:compressed, :future_algorithm, :erlang.term_to_binary(value)}
      nested_value = String.duplicate("legacy", 10_000)
      nested_etf = :erlang.term_to_binary(nested_value, compressed: 9)
      assert <<131, 80, _rest::binary>> = nested_etf
      nested_etf_envelope = {:compressed, :none, nested_etf}

      assert ^value = Compression.decompress(legacy_envelope)
      assert ^nested_value = Compression.decompress(nested_etf_envelope)
      assert {:error, :invalid_compressed_value} = Compression.safe_decompress(legacy_envelope)

      assert {:error, :invalid_compressed_value} =
               Compression.safe_decompress(nested_etf_envelope)

      put = CommandEnvelope.wrap(1_000, {:put, "legacy", legacy_envelope, nil}, 0)
      assert {:ok, state} = VSRStateMachine.apply(metadata(1), put, Core.init())

      compare_and_swap =
        CommandEnvelope.wrap(1_001, {:put_if, "legacy", "next", nil, value}, 0)

      assert {:ok, state} = VSRStateMachine.apply(metadata(2), compare_and_swap, state)
      assert {:ok, "next"} = Core.query({:get, "legacy"}, state, %{timestamp_ms: 1_001})
    end

    test "VSR command validation rejects compressed unsafe and malformed values" do
      unsafe = Compression.compress(fn -> :unsafe end, force: true, threshold: 0)
      malformed = {:compressed, :zlib, <<1, 2, 3>>}

      assert {:error, {:invalid_command, :function_in_spec}} =
               Concord.Engine.VSR.command({:put, "unsafe", unsafe, %{}})

      assert {:error, {:invalid_command, :invalid_compressed_value}} =
               Concord.Engine.VSR.command({:put, "malformed", malformed, %{}})
    end
  end

  describe "public write validation" do
    test "rejects unsafe logical values before forced compression" do
      unsafe = %{callback: fn -> :unsafe end, padding: String.duplicate("x", 2_048)}

      assert {:error, :function_in_spec} = Concord.put("unsafe", unsafe, compress: true)
      assert {:error, :function_in_spec} = KV.put("unsafe", unsafe, compress: true)
      assert {:error, :function_in_spec} = KV.create("unsafe", unsafe, compress: true)
      assert {:error, :function_in_spec} = KV.replace("unsafe", unsafe, compress: true)

      assert {:error, :function_in_spec} =
               KV.update_if("unsafe", unsafe, compress: true, mod_revision: 1)

      assert {:error, :function_in_spec} =
               Concord.put_if("unsafe", unsafe, compress: true, expected: :old)

      assert {:error, :function_in_spec} = Concord.put_many([{"unsafe", unsafe}])
    end

    test "rejects malformed compression envelopes before dispatch" do
      malformed = {:compressed, :zlib, <<1, 2, 3>>}

      assert {:error, :invalid_compressed_value} =
               Concord.put("malformed", malformed, compress: false)

      assert {:error, :invalid_compressed_value} =
               KV.put("malformed", malformed, compress: false)
    end
  end

  defp metadata(op_number) do
    %ApplyMetadata{
      group_id: :compression_validation,
      view_number: 0,
      op_number: op_number,
      client_id: :client,
      request_number: op_number
    }
  end
end
