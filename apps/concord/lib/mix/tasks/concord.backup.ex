defmodule Mix.Tasks.Concord.Backup do
  @moduledoc """
  Concord backup management tasks.

  ## Usage

      # Create a backup
      mix concord.backup create

      # Create backup in specific directory
      mix concord.backup create --path /mnt/backups

      # List available backups
      mix concord.backup list

      # Restore from backup
      mix concord.backup restore <backup_file>

      # Verify backup integrity
      mix concord.backup verify <backup_file>

      # Clean up old backups
      mix concord.backup cleanup --keep-count 5

  """

  use Mix.Task
  require Logger

  alias Concord.Backup

  @shortdoc "Manage Concord backups"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case args do
      ["create" | opts] -> create_backup(opts)
      ["list" | opts] -> list_backups(opts)
      ["restore", backup_path | opts] -> restore_backup(backup_path, opts)
      ["verify", backup_path] -> verify_backup(backup_path)
      ["cleanup" | opts] -> cleanup_backups(opts)
      _ -> print_usage()
    end
  end

  defp create_backup(opts) do
    parsed_opts =
      parse_opts(opts,
        path: :string,
        compress: :boolean
      )

    IO.puts("Creating backup...")

    case Backup.create(parsed_opts) do
      {:ok, backup_path} ->
        IO.puts("✓ Backup created successfully!")
        IO.puts("  Path: #{backup_path}")

        # Get backup info
        case File.stat(backup_path) do
          {:ok, %{size: size}} ->
            IO.puts("  Size: #{format_bytes(size)}")

          _ ->
            :ok
        end

      {:error, reason} ->
        IO.puts("✗ Failed to create backup: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp list_backups(opts) do
    parsed_opts = parse_opts(opts, path: :string)
    backup_dir = Keyword.get(parsed_opts, :path, "./backups")

    IO.puts("Listing backups in: #{backup_dir}\n")

    case Backup.list(backup_dir) do
      {:ok, []} ->
        IO.puts("No backups found.")

      {:ok, backups} ->
        IO.puts("Found #{length(backups)} backup(s):\n")

        Enum.each(backups, fn backup ->
          IO.puts("Backup: #{Path.basename(backup.path)}")
          IO.puts("  Created: #{DateTime.to_string(backup.timestamp)}")
          IO.puts("  Entries: #{backup.entry_count}")
          IO.puts("  Size: #{format_bytes(backup.size_bytes)}")
          IO.puts("  Node: #{backup.node}")
          IO.puts("  Version: #{backup.version}")
          IO.puts("")
        end)

      {:error, reason} ->
        IO.puts("✗ Failed to list backups: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp restore_backup(backup_path, opts) do
    parsed_opts =
      parse_opts(opts,
        force: :boolean,
        verify: :boolean
      )

    force = Keyword.get(parsed_opts, :force, false)

    unless force do
      IO.puts("⚠️  WARNING: This will overwrite all data in the cluster!")
      IO.write("Are you sure you want to continue? (yes/no): ")

      case IO.gets("") |> String.trim() |> String.downcase() do
        "yes" ->
          :ok

        _ ->
          IO.puts("Restore cancelled.")
          exit({:shutdown, 0})
      end
    end

    IO.puts("\nRestoring from backup: #{backup_path}")

    case Backup.restore(backup_path, parsed_opts) do
      :ok ->
        IO.puts("✓ Backup restored successfully!")

      {:error, :file_not_found} ->
        IO.puts("✗ Backup file not found: #{backup_path}")
        exit({:shutdown, 1})

      {:error, :invalid_backup} ->
        IO.puts("✗ Backup file is corrupted or invalid")
        exit({:shutdown, 1})

      {:error, reason} ->
        IO.puts("✗ Failed to restore backup: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp verify_backup(backup_path) do
    IO.puts("Verifying backup: #{backup_path}")

    case Backup.verify(backup_path) do
      {:ok, :valid} ->
        IO.puts("✓ Backup is valid")

      {:ok, :invalid} ->
        IO.puts("✗ Backup is corrupted (checksum mismatch)")
        exit({:shutdown, 1})

      {:error, reason} ->
        IO.puts("✗ Failed to verify backup: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp cleanup_backups(opts) do
    parsed_opts =
      parse_opts(opts,
        path: :string,
        keep_count: :integer,
        keep_days: :integer
      )

    backup_dir = Keyword.get(parsed_opts, :path, "./backups")
    keep_count = Keyword.get(parsed_opts, :keep_count, 10)
    keep_days = Keyword.get(parsed_opts, :keep_days, 30)

    IO.puts("Cleaning up backups in: #{backup_dir}")
    IO.puts("  Keep count: #{keep_count}")
    IO.puts("  Keep days: #{keep_days}\n")

    case Backup.cleanup(parsed_opts) do
      {:ok, 0} ->
        IO.puts("✓ No backups to delete")

      {:ok, count} ->
        IO.puts("✓ Deleted #{count} old backup(s)")

      {:error, reason} ->
        IO.puts("✗ Failed to cleanup backups: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp print_usage do
    IO.puts("""
    Concord Backup Management

    Usage:
      mix concord.backup create [options]       Create a new backup
      mix concord.backup list [options]         List available backups
      mix concord.backup restore <file> [opts]  Restore from backup
      mix concord.backup verify <file>          Verify backup integrity
      mix concord.backup cleanup [options]      Clean up old backups

    Options:
      --path <dir>          Backup directory (default: ./backups)
      --compress            Compress backup (default: true)
      --force               Skip confirmation prompts
      --verify              Verify before restore (default: true)
      --keep-count <n>      Number of backups to keep (default: 10)
      --keep-days <n>       Keep backups newer than N days (default: 30)

    Examples:
      mix concord.backup create
      mix concord.backup create --path /mnt/backups
      mix concord.backup list
      mix concord.backup restore ./backups/concord_backup_20251023.backup
      mix concord.backup restore ./backups/concord_backup_20251023.backup --force
      mix concord.backup verify ./backups/concord_backup_20251023.backup
      mix concord.backup cleanup --keep-count 5
    """)
  end

  defp parse_opts(args, schema) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: schema,
        aliases: [
          p: :path,
          f: :force,
          v: :verify,
          c: :compress
        ]
      )

    # Convert string values to appropriate types
    Enum.map(opts, fn
      {:keep_count, val} when is_binary(val) -> {:keep_count, String.to_integer(val)}
      {:keep_days, val} when is_binary(val) -> {:keep_days, String.to_integer(val)}
      {key, val} -> {key, val}
    end)
  end

  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"

  defp format_bytes(bytes) when bytes < 1024 * 1024 do
    "#{Float.round(bytes / 1024, 2)} KB"
  end

  defp format_bytes(bytes) when bytes < 1024 * 1024 * 1024 do
    "#{Float.round(bytes / (1024 * 1024), 2)} MB"
  end

  defp format_bytes(bytes) do
    "#{Float.round(bytes / (1024 * 1024 * 1024), 2)} GB"
  end
end
