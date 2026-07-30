defmodule Concord.CommandEmissionTest do
  use ExUnit.Case, async: true

  alias Concord.CommandSchema

  test "canonicalizes infinite TTLs in direct and transactional puts" do
    assert {:put, "direct", "value", %{ttl: nil, metadata: %{source: "test"}}} =
             CommandSchema.normalize_emission(
               {:put, "direct", "value", %{ttl: :infinity, metadata: %{source: "test"}}}
             )

    command =
      {:txn,
       %{
         compare: [{:exists, "direct", :==, true}],
         success: [{:put, "success", "value", %{ttl: :infinity}}],
         failure: [{:put, "failure", "value", %{ttl: :infinity, prev_kv: true}}]
       }}

    assert {:txn,
            %{
              compare: [{:exists, "direct", :==, true}],
              success: [{:put, "success", "value", %{ttl: nil}}],
              failure: [{:put, "failure", "value", %{ttl: nil, prev_kv: true}}]
            }} = CommandSchema.normalize_emission(command)
  end

  test "leaves historical absolute-expiry and unrelated command shapes unchanged" do
    absolute_expiry = {:put, "legacy", "value", 1_000}
    unknown = {:command_from_an_older_release, %{payload: true}}

    assert CommandSchema.normalize_emission(absolute_expiry) == absolute_expiry
    assert CommandSchema.normalize_emission(unknown) == unknown
  end
end
