defmodule Concord.KV.SelectorTest do
  use ExUnit.Case, async: true

  alias Concord.KV.Selector

  describe "validate/1" do
    test "accepts valid key selector" do
      assert :ok = Selector.validate({:key, "mykey"})
    end

    test "rejects empty key" do
      assert {:error, :empty_key} = Selector.validate({:key, ""})
    end

    test "accepts valid prefix selector" do
      assert :ok = Selector.validate({:prefix, "/tasks/"})
    end

    test "rejects empty prefix" do
      assert {:error, :prefix_too_short} = Selector.validate({:prefix, ""})
    end

    test "accepts valid range selector" do
      assert :ok = Selector.validate({:range, "a", "z"})
    end

    test "rejects inverted range" do
      assert {:error, :invalid_range} = Selector.validate({:range, "z", "a"})
    end

    test "rejects equal range bounds" do
      assert {:error, :invalid_range} = Selector.validate({:range, "a", "a"})
    end

    test "rejects unknown selector" do
      assert {:error, :invalid_selector} = Selector.validate(:bad)
    end
  end

  describe "matches?/2" do
    test "key selector matches exact key" do
      assert Selector.matches?({:key, "foo"}, "foo") == true
    end

    test "key selector rejects different key" do
      assert Selector.matches?({:key, "foo"}, "bar") == false
    end

    test "prefix selector matches matching prefix" do
      assert Selector.matches?({:prefix, "/tasks/"}, "/tasks/123") == true
    end

    test "prefix selector matches exact prefix" do
      assert Selector.matches?({:prefix, "/tasks/"}, "/tasks/") == true
    end

    test "prefix selector rejects non-matching" do
      assert Selector.matches?({:prefix, "/tasks/"}, "/jobs/123") == false
    end

    test "range selector matches keys in range" do
      assert Selector.matches?({:range, "a", "d"}, "b") == true
      assert Selector.matches?({:range, "a", "d"}, "c") == true
    end

    test "range selector includes start, excludes end" do
      assert Selector.matches?({:range, "a", "d"}, "a") == true
      assert Selector.matches?({:range, "a", "d"}, "d") == false
    end

    test "range selector rejects out-of-range" do
      assert Selector.matches?({:range, "b", "d"}, "a") == false
      assert Selector.matches?({:range, "b", "d"}, "e") == false
    end
  end

  describe "prefix_end/1" do
    test "appends 0xFF byte" do
      assert Selector.prefix_end("abc") == "abc" <> <<0xFF>>
    end
  end
end
