defmodule ViewstampedReplication.Telemetry do
  @moduledoc """
  Thin, optional-to-observe telemetry boundary for the runtime.
  """

  @prefix [:viewstamped_replication]

  @spec execute([atom()], map(), map()) :: :ok
  def execute(event, measurements \\ %{}, metadata \\ %{})
      when is_list(event) and is_map(measurements) and is_map(metadata) do
    :telemetry.execute(@prefix ++ event, measurements, metadata)
  end

  @spec span([atom()], map(), (-> {term(), map()})) :: term()
  def span(event, metadata, function)
      when is_list(event) and is_map(metadata) and is_function(function, 0) do
    :telemetry.span(@prefix ++ event, metadata, function)
  end
end
