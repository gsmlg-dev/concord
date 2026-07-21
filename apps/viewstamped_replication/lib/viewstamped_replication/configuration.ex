defmodule ViewstampedReplication.Configuration do
  @moduledoc """
  An explicit, ordered, fixed-membership VSR configuration.

  Membership order is significant: it determines the primary for each view and
  is included in the configuration hash.
  """

  alias ViewstampedReplication.Member

  @supported_member_counts 1..6
  @enforce_keys [:group_id, :replica_id, :members]
  defstruct [:group_id, :replica_id, :members]

  @type t :: %__MODULE__{
          group_id: term(),
          replica_id: Member.id(),
          members: [Member.t()]
        }

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attributes) when is_list(attributes) do
    attributes
    |> Map.new()
    |> new()
  end

  def new(attributes) when is_map(attributes) do
    configuration =
      struct(__MODULE__, Map.take(attributes, [:group_id, :replica_id, :members]))

    validate(configuration)
  end

  @spec new!(keyword() | map()) :: t()
  def new!(attributes) do
    case new(attributes) do
      {:ok, configuration} -> configuration
      {:error, reason} -> raise ArgumentError, "invalid VSR configuration: #{inspect(reason)}"
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, term()}
  def validate(%__MODULE__{group_id: group_id}) when is_nil(group_id),
    do: {:error, :group_id_required}

  def validate(%__MODULE__{members: members}) when not is_list(members),
    do: {:error, :members_must_be_a_list}

  def validate(%__MODULE__{members: members})
      when length(members) not in @supported_member_counts,
      do: {:error, {:unsupported_member_count, length(members)}}

  def validate(%__MODULE__{} = configuration) do
    with :ok <- validate_members(configuration.members),
         :ok <- validate_local_member(configuration) do
      {:ok, configuration}
    end
  end

  @spec member_count(t()) :: pos_integer()
  def member_count(%__MODULE__{members: members}), do: length(members)

  @spec failure_threshold(t()) :: non_neg_integer()
  def failure_threshold(%__MODULE__{} = configuration) do
    div(member_count(configuration) - 1, 2)
  end

  @spec quorum_size(t()) :: pos_integer()
  def quorum_size(%__MODULE__{} = configuration) do
    div(member_count(configuration), 2) + 1
  end

  @spec primary_id(t(), non_neg_integer()) :: Member.id()
  def primary_id(%__MODULE__{members: members}, view_number)
      when is_integer(view_number) and view_number >= 0 do
    members
    |> Enum.at(rem(view_number, length(members)))
    |> Map.fetch!(:id)
  end

  @spec hash(t()) :: binary()
  def hash(%__MODULE__{group_id: group_id, members: members}) do
    identity = {group_id, Enum.map(members, &{&1.id, &1.endpoint})}
    :crypto.hash(:sha256, :erlang.term_to_binary(identity, [:deterministic]))
  end

  @spec hash_hex(t()) :: String.t()
  def hash_hex(%__MODULE__{} = configuration) do
    configuration
    |> hash()
    |> Base.encode16(case: :lower)
  end

  defp validate_members(members) do
    with :ok <- validate_member_shapes(members),
         :ok <- validate_unique(members, :id, :duplicate_member_ids),
         :ok <- validate_unique(members, :endpoint, :duplicate_member_endpoints) do
      :ok
    end
  end

  defp validate_member_shapes(members) do
    if Enum.all?(
         members,
         &match?(
           %Member{id: id, endpoint: endpoint} when not is_nil(id) and not is_nil(endpoint),
           &1
         )
       ) do
      :ok
    else
      {:error, :invalid_member}
    end
  end

  defp validate_unique(members, field, error) do
    values = Enum.map(members, &Map.fetch!(&1, field))

    if MapSet.size(MapSet.new(values)) == length(values), do: :ok, else: {:error, error}
  end

  defp validate_local_member(%__MODULE__{replica_id: replica_id, members: members}) do
    if Enum.any?(members, &(&1.id == replica_id)),
      do: :ok,
      else: {:error, :replica_id_not_in_members}
  end
end
