defmodule ConcordTest do
  use ExUnit.Case
  doctest Concord

  test "greets the world" do
    assert Concord.hello() == :world
  end
end
