defmodule Concord.ValidationTest do
  use ExUnit.Case, async: true

  alias Concord.Validation

  describe "validate_term/1" do
    test "accepts atoms" do
      assert :ok = Validation.validate_term(:hello)
    end

    test "accepts numbers" do
      assert :ok = Validation.validate_term(42)
      assert :ok = Validation.validate_term(3.14)
    end

    test "accepts binaries" do
      assert :ok = Validation.validate_term("hello")
    end

    test "accepts lists" do
      assert :ok = Validation.validate_term([1, 2, 3])
    end

    test "accepts maps" do
      assert :ok = Validation.validate_term(%{a: 1, b: 2})
    end

    test "accepts nested structures" do
      term = %{users: [%{name: "Alice", roles: [:admin]}]}
      assert :ok = Validation.validate_term(term)
    end

    test "accepts tuples" do
      assert :ok = Validation.validate_term({:ok, "value"})
    end

    test "rejects anonymous functions" do
      assert {:error, :function_in_spec} = Validation.validate_term(fn x -> x end)
    end

    test "rejects functions nested in maps" do
      term = %{callback: fn -> :ok end}
      assert {:error, :function_in_spec} = Validation.validate_term(term)
    end

    test "rejects PIDs" do
      assert {:error, :pid_in_spec} = Validation.validate_term(self())
    end

    test "rejects references" do
      assert {:error, :ref_in_spec} = Validation.validate_term(make_ref())
    end

    test "rejects deeply nested forbidden values" do
      term = %{a: %{b: %{c: [fn -> :bad end]}}}
      assert {:error, :function_in_spec} = Validation.validate_term(term)
    end

    test "rejects terms exceeding max depth" do
      # Build a deeply nested structure
      deep = Enum.reduce(1..101, :leaf, fn _, acc -> %{nested: acc} end)
      assert {:error, :depth_exceeded} = Validation.validate_term(deep)
    end
  end

  describe "validate_txn_spec/1" do
    test "accepts valid minimal spec" do
      spec = %{compare: [], success: [], failure: []}
      assert :ok = Validation.validate_txn_spec(spec)
    end

    test "accepts valid spec with compares and ops" do
      spec = %{
        compare: [{:exists, "key", :==, false}],
        success: [{:put, "key", "value", %{}}],
        failure: []
      }

      assert :ok = Validation.validate_txn_spec(spec)
    end

    test "accepts spec with all compare types" do
      spec = %{
        compare: [
          {:exists, "k1", :==, true},
          {:value, "k2", :!=, nil},
          {:version, "k3", :>, 0},
          {:create_revision, "k4", :>=, 1},
          {:mod_revision, "k5", :<, 100},
          {:lease, "k6", :==, nil},
          {:ttl, "k7", :<=, 30}
        ],
        success: [],
        failure: []
      }

      assert :ok = Validation.validate_txn_spec(spec)
    end

    test "accepts spec with get, put, delete, touch ops" do
      spec = %{
        compare: [],
        success: [
          {:get, {:key, "k"}, %{}},
          {:put, "k", "v", %{}},
          {:delete, {:key, "k"}, %{}},
          {:touch, "k", 30, %{}}
        ],
        failure: []
      }

      assert :ok = Validation.validate_txn_spec(spec)
    end

    test "rejects non-map spec" do
      assert {:error, {:invalid_txn, :invalid_spec}} = Validation.validate_txn_spec("bad")
    end

    test "rejects too many compares" do
      compares = for i <- 1..65, do: {:exists, "k#{i}", :==, true}
      spec = %{compare: compares, success: [], failure: []}
      assert {:error, {:invalid_txn, :too_many_compares}} = Validation.validate_txn_spec(spec)
    end

    test "rejects invalid compare field" do
      spec = %{compare: [{:bad_field, "key", :==, true}], success: [], failure: []}
      assert {:error, {:invalid_txn, :unsupported_compare_field}} = Validation.validate_txn_spec(spec)
    end

    test "rejects invalid compare operator" do
      spec = %{compare: [{:exists, "key", :match, true}], success: [], failure: []}
      assert {:error, {:invalid_txn, :unsupported_compare_op}} = Validation.validate_txn_spec(spec)
    end

    test "rejects spec with functions" do
      spec = %{compare: [], success: [{:put, "k", fn -> :bad end, %{}}], failure: []}
      assert {:error, :function_in_spec} = Validation.validate_txn_spec(spec)
    end

    test "rejects empty key in put op" do
      spec = %{compare: [], success: [{:put, "", "v", %{}}], failure: []}
      assert {:error, {:invalid_txn, :empty_key}} = Validation.validate_txn_spec(spec)
    end

    test "rejects key too large in put op" do
      big_key = String.duplicate("x", 1025)
      spec = %{compare: [], success: [{:put, big_key, "v", %{}}], failure: []}
      assert {:error, {:invalid_txn, :key_too_large}} = Validation.validate_txn_spec(spec)
    end
  end
end
