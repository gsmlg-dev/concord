defmodule Concord.Deadline do
  @moduledoc false

  def start(opts, default_timeout \\ 5_000) do
    timeout = Keyword.get(opts, :timeout, default_timeout)

    if timeout == :infinity do
      Keyword.put_new(opts, :deadline, :infinity)
    else
      Keyword.put_new(opts, :deadline, System.monotonic_time(:millisecond) + timeout)
    end
  end

  def remaining(opts) do
    case Keyword.fetch!(opts, :deadline) do
      :infinity -> :infinity
      deadline -> max(deadline - System.monotonic_time(:millisecond), 0)
    end
  end

  def check(opts) do
    if remaining(opts) == 0, do: {:error, :timeout}, else: :ok
  end
end
