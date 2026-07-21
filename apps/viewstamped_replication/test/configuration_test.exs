defmodule ViewstampedReplication.ConfigurationTest do
  use ExUnit.Case, async: true

  alias ViewstampedReplication.{Configuration, Member}

  test "supports one through six members with strict majority quorums" do
    expected = [
      {1, 0, 1},
      {2, 0, 2},
      {3, 1, 2},
      {4, 1, 3},
      {5, 2, 3},
      {6, 2, 4}
    ]

    for {member_count, failure_threshold, quorum_size} <- expected do
      configuration = configuration(1, member_count)

      assert {:ok, ^configuration} = Configuration.validate(configuration)
      assert Configuration.member_count(configuration) == member_count
      assert Configuration.failure_threshold(configuration) == failure_threshold
      assert Configuration.quorum_size(configuration) == quorum_size
    end
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

  test "rejects empty configurations and configurations larger than six members" do
    assert {:error, {:unsupported_member_count, 0}} =
             Configuration.validate(configuration(1, 0))

    assert {:error, {:unsupported_member_count, 7}} =
             Configuration.validate(configuration(1, 7))
  end

  defp configuration(replica_id, member_count \\ 3) do
    %Configuration{
      group_id: :group,
      replica_id: replica_id,
      members:
        for(member_id <- 1..member_count//1,
          do: %Member{id: member_id, endpoint: {:replica, member_id}}
        )
    }
  end
end
