defmodule Mix.Tasks.Concord.Cluster do
  @moduledoc """
  Mix tasks for managing Concord clusters.
  """

  use Mix.Task

  @shortdoc "Manages Concord cluster operations"

  def run(["status" | _]) do
    Mix.Task.run("app.start")

    case Concord.status() do
      {:ok, status} ->
        Mix.shell().info("Cluster Status:")
        Mix.shell().info("Node: #{status.node}")
        Mix.shell().info("\nCluster Overview:")
        Mix.shell().info(inspect(status.cluster, pretty: true))
        Mix.shell().info("\nStorage Stats:")
        Mix.shell().info("  Size: #{status.storage.size} entries")
        Mix.shell().info("  Memory: #{status.storage.memory} words")

      {:error, reason} ->
        Mix.shell().error("Failed to get cluster status: #{inspect(reason)}")
    end
  end

  def run(["members" | _]) do
    Mix.Task.run("app.start")

    case Concord.members() do
      {:ok, members} ->
        Mix.shell().info("Cluster Members:")

        Enum.each(members, fn member ->
          Mix.shell().info("  - #{inspect(member)}")
        end)

      {:error, reason} ->
        Mix.shell().error("Failed to get members: #{inspect(reason)}")
    end
  end

  def run(["token", "create" | _]) do
    Mix.Task.run("app.start")

    {:ok, token} = Concord.Auth.create_token([:read, :write])
    Mix.shell().info("Created token: #{token}")
    Mix.shell().info("Save this token securely!")
  end

  def run(["token", "revoke", token | _]) do
    Mix.Task.run("app.start")

    :ok = Concord.Auth.revoke_token(token)
    Mix.shell().info("Token revoked successfully")
  end

  def run(_) do
    Mix.shell().info("""
    Usage:
      mix concord.cluster status        - Show cluster status
      mix concord.cluster members       - List cluster members
      mix concord.cluster token create  - Create authentication token
      mix concord.cluster token revoke TOKEN - Revoke a token
    """)
  end
end
