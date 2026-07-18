defmodule ViewstampedReplication.ConfigurationTest do
  use ExUnit.Case, async: true

  alias ViewstampedReplication.{Configuration, Member}

  test "validates membership and derives quorum values" do
    configuration = configuration(2)

    assert {:ok, ^configuration} = Configuration.validate(configuration)
    assert Configuration.member_count(configuration) == 3
    assert Configuration.failure_threshold(configuration) == 1
    assert Configuration.quorum_size(configuration) == 2
  end

  test "rotates the primary through the ordered configuration" do
    configuration = configuration(1)

    assert Configuration.primary_id(configuration, 0) == 1
    assert Configuration.primary_id(configuration, 1) == 2
    assert Configuration.primary_id(configuration, 2) == 3
    assert Configuration.primary_id(configuration, 3) == 1
  end

  test "uses one shared hash while retaining membership order" do
    first = configuration(1)
    another_replica = configuration(3)
    reordered = %{first | members: Enum.reverse(first.members)}

    assert Configuration.hash(first) == Configuration.hash(another_replica)
    refute Configuration.hash(first) == Configuration.hash(reordered)
  end

  test "rejects missing group and invalid local replica" do
    assert {:error, :group_id_required} =
             configuration(1)
             |> Map.put(:group_id, nil)
             |> Configuration.validate()

    assert {:error, :replica_id_not_in_members} =
             configuration(:unknown)
             |> Configuration.validate()
  end

  test "rejects duplicate member identities and endpoints" do
    [first, second, third] = configuration(1).members

    assert {:error, :duplicate_member_ids} =
             Configuration.validate(%{
               configuration(1)
               | members: [first, %{second | id: 1}, third]
             })

    assert {:error, :duplicate_member_endpoints} =
             Configuration.validate(%{
               configuration(1)
               | members: [first, %{second | endpoint: first.endpoint}, third]
             })
  end

  test "supports only one, three, or five members" do
    assert {:error, {:unsupported_member_count, 2}} =
             Configuration.validate(%{
               configuration(1)
               | members: Enum.take(configuration(1).members, 2)
             })
  end

  defp configuration(replica_id) do
    %Configuration{
      group_id: :group,
      replica_id: replica_id,
      members: [
        %Member{id: 1, endpoint: :one},
        %Member{id: 2, endpoint: :two},
        %Member{id: 3, endpoint: :three}
      ]
    }
  end
end
