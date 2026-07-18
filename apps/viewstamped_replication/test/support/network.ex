defmodule ViewstampedReplication.Test.Network do
  @moduledoc false

  defstruct partitions: MapSet.new()

  @type replica_id :: term()
  @type link :: {replica_id(), replica_id()}
  @type t :: %__MODULE__{partitions: MapSet.t(link())}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec partition(t(), replica_id() | [replica_id()], replica_id() | [replica_id()]) :: t()
  def partition(%__MODULE__{} = network, left, right) do
    links =
      for from <- List.wrap(left),
          to <- List.wrap(right),
          from != to,
          direction <- [{from, to}, {to, from}],
          do: direction

    %{network | partitions: Enum.reduce(links, network.partitions, &MapSet.put(&2, &1))}
  end

  @spec heal(t()) :: t()
  def heal(%__MODULE__{} = network), do: %{network | partitions: MapSet.new()}

  @spec heal(t(), replica_id() | [replica_id()], replica_id() | [replica_id()]) :: t()
  def heal(%__MODULE__{} = network, left, right) do
    links =
      for from <- List.wrap(left),
          to <- List.wrap(right),
          from != to,
          direction <- [{from, to}, {to, from}],
          do: direction

    %{network | partitions: Enum.reduce(links, network.partitions, &MapSet.delete(&2, &1))}
  end

  @spec connected?(t(), replica_id(), replica_id()) :: boolean()
  def connected?(%__MODULE__{partitions: partitions}, from, to) do
    not MapSet.member?(partitions, {from, to})
  end
end
