defmodule Concord.Backup do
  @moduledoc """
  Backup and restore functionality for Concord distributed KV store.

  Provides comprehensive backup management including:
  - Local and remote backup creation
  - Point-in-time recovery
  - Backup verification and integrity checks
  - Compressed backup storage
  - Metadata tracking

  ## Backup Format

  Backups are stored as compressed Erlang term files (.backup) containing:
  - Metadata (timestamp, cluster info, entry count)
  - Full snapshot of all key-value pairs
  - Checksum for integrity verification

  ## Examples

      # Create a backup
      {:ok, path} = Concord.Backup.create("/path/to/backups")

      # Restore from backup
      :ok = Concord.Backup.restore("/path/to/backup.backup")

      # List available backups
      {:ok, backups} = Concord.Backup.list("/path/to/backups")

      # Verify backup integrity
      {:ok, :valid} = Concord.Backup.verify("/path/to/backup.backup")
  """

  require Logger

  @backup_extension ".backup"
  @default_backup_dir "./backups"

  @typedoc "Backup metadata"
  @type metadata :: %{
    timestamp: DateTime.t(),
    node: node(),
    cluster_name: atom(),
    entry_count: non_neg_integer(),
    memory_bytes: non_neg_integer(),
    version: String.t(),
    checksum: binary()
  }

  @typedoc "Backup content"
  @type backup :: %{
    metadata: metadata(),
    data: list({term(), term()})
  }

  @doc """
  Creates a backup of the current cluster state.

  ## Options

  - `:path` - Directory to store backup (default: "./backups")
  - `:compress` - Compress backup file (default: true)
  - `:include_metadata` - Include cluster metadata (default: true)

  ## Returns

  - `{:ok, backup_path}` - Path to created backup file
  - `{:error, reason}` - Error creating backup

  ## Examples

      iex> Concord.Backup.create()
      {:ok, "./backups/concord_backup_20251023_143052.backup"}

      iex> Concord.Backup.create(path: "/mnt/backups")
      {:ok, "/mnt/backups/concord_backup_20251023_143052.backup"}
  """
  @spec create(keyword()) :: {:ok, Path.t()} | {:error, term()}
  def create(opts \\ []) do
    backup_dir = Keyword.get(opts, :path, @default_backup_dir)
    compress = Keyword.get(opts, :compress, true)

    with :ok <- File.mkdir_p(backup_dir),
         {:ok, snapshot} <- get_cluster_snapshot(),
         {:ok, backup_data} <- build_backup(snapshot),
         {:ok, backup_path} <- write_backup(backup_dir, backup_data, compress) do
      Logger.info("Backup created successfully: #{backup_path}")
      {:ok, backup_path}
    else
      {:error, reason} = error ->
        Logger.error("Failed to create backup: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Restores cluster state from a backup file.

  **Warning**: This operation will overwrite all existing data in the cluster.
  It's recommended to create a backup before restoring.

  ## Options

  - `:force` - Skip confirmation prompts (default: false)
  - `:verify` - Verify backup integrity before restore (default: true)

  ## Returns

  - `:ok` - Restore completed successfully
  - `{:error, reason}` - Error during restore

  ## Examples

      iex> Concord.Backup.restore("/path/to/backup.backup")
      :ok

      iex> Concord.Backup.restore("/path/to/backup.backup", force: true)
      :ok
  """
  @spec restore(Path.t(), keyword()) :: :ok | {:error, term()}
  def restore(backup_path, opts \\ []) do
    verify = Keyword.get(opts, :verify, true)

    with {:exists, true} <- {:exists, File.exists?(backup_path)},
         {:verify, {:ok, :valid}} <- maybe_verify(backup_path, verify),
         {:ok, backup_data} <- read_backup(backup_path),
         :ok <- apply_backup(backup_data) do
      Logger.info("Backup restored successfully from: #{backup_path}")
      :ok
    else
      {:exists, false} ->
        {:error, :file_not_found}

      {:verify, {:ok, :invalid}} ->
        {:error, :invalid_backup}

      {:verify, {:error, reason}} ->
        {:error, {:verification_failed, reason}}

      {:error, reason} = error ->
        Logger.error("Failed to restore backup: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Lists all available backups in a directory.

  ## Returns

  - `{:ok, backup_list}` - List of backup file information
  - `{:error, reason}` - Error reading directory

  ## Examples

      iex> Concord.Backup.list()
      {:ok, [
        %{
          path: "./backups/concord_backup_20251023_143052.backup",
          timestamp: ~U[2025-10-23 14:30:52Z],
          size_bytes: 1048576,
          entry_count: 1000
        }
      ]}
  """
  @spec list(Path.t()) :: {:ok, list(map())} | {:error, term()}
  def list(backup_dir \\ @default_backup_dir) do
    case File.ls(backup_dir) do
      {:ok, files} ->
        backups =
          files
          |> Enum.filter(&String.ends_with?(&1, @backup_extension))
          |> Enum.map(fn file ->
            path = Path.join(backup_dir, file)
            get_backup_info(path)
          end)
          |> Enum.reject(&is_nil/1)
          |> Enum.sort_by(& &1.timestamp, {:desc, DateTime})

        {:ok, backups}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Verifies the integrity of a backup file.

  ## Returns

  - `{:ok, :valid}` - Backup is valid
  - `{:ok, :invalid}` - Backup is corrupted
  - `{:error, reason}` - Error reading backup

  ## Examples

      iex> Concord.Backup.verify("/path/to/backup.backup")
      {:ok, :valid}
  """
  @spec verify(Path.t()) :: {:ok, :valid | :invalid} | {:error, term()}
  def verify(backup_path) do
    with {:ok, backup_data} <- read_backup(backup_path),
         {:ok, :valid} <- verify_checksum(backup_data) do
      {:ok, :valid}
    else
      {:ok, :invalid} -> {:ok, :invalid}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Deletes old backups based on retention policy.

  ## Options

  - `:keep_count` - Number of backups to keep (default: 10)
  - `:keep_days` - Keep backups newer than N days (default: 30)

  ## Returns

  - `{:ok, deleted_count}` - Number of backups deleted
  - `{:error, reason}` - Error during cleanup

  ## Examples

      iex> Concord.Backup.cleanup(keep_count: 5)
      {:ok, 3}

      iex> Concord.Backup.cleanup(keep_days: 7)
      {:ok, 10}
  """
  @spec cleanup(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def cleanup(opts \\ []) do
    backup_dir = Keyword.get(opts, :path, @default_backup_dir)
    keep_count = Keyword.get(opts, :keep_count, 10)
    keep_days = Keyword.get(opts, :keep_days, 30)

    with {:ok, backups} <- list(backup_dir) do
      cutoff_date = DateTime.add(DateTime.utc_now(), -keep_days, :day)

      to_delete =
        backups
        |> Enum.sort_by(& &1.timestamp, {:desc, DateTime})
        |> Enum.drop(keep_count)
        |> Enum.filter(fn backup ->
          DateTime.compare(backup.timestamp, cutoff_date) == :lt
        end)

      deleted_count =
        Enum.reduce(to_delete, 0, fn backup, acc ->
          case File.rm(backup.path) do
            :ok ->
              Logger.info("Deleted old backup: #{backup.path}")
              acc + 1

            {:error, reason} ->
              Logger.warning("Failed to delete backup #{backup.path}: #{inspect(reason)}")
              acc
          end
        end)

      {:ok, deleted_count}
    end
  end

  # Private functions

  defp get_cluster_snapshot do
    server_id = {Application.get_env(:concord, :cluster_name, :concord_cluster), node()}

    case :ra.consistent_query(server_id, fn state -> {:concord_kv, state} end) do
      {:ok, {:concord_kv, _state}, _leader} ->
        # Get snapshot from ETS table
        data = :ets.tab2list(:concord_store)
        {:ok, data}

      {:error, reason} ->
        {:error, reason}

      {:timeout, _} ->
        {:error, :timeout}
    end
  end

  defp build_backup(snapshot_data) do
    metadata = %{
      timestamp: DateTime.utc_now(),
      node: node(),
      cluster_name: Application.get_env(:concord, :cluster_name, :concord_cluster),
      entry_count: length(snapshot_data),
      memory_bytes: :erlang.external_size(snapshot_data),
      version: Application.spec(:concord, :vsn) |> to_string(),
      checksum: compute_checksum(snapshot_data)
    }

    backup = %{
      metadata: metadata,
      data: snapshot_data
    }

    {:ok, backup}
  end

  defp write_backup(backup_dir, backup_data, compress) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601(:basic) |> String.replace(":", "")
    filename = "concord_backup_#{timestamp}#{@backup_extension}"
    backup_path = Path.join(backup_dir, filename)

    encoded = :erlang.term_to_binary(backup_data, [:compressed | if(compress, do: [], else: [])])

    case File.write(backup_path, encoded) do
      :ok -> {:ok, backup_path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_backup(backup_path) do
    case File.read(backup_path) do
      {:ok, binary} ->
        try do
          data = :erlang.binary_to_term(binary)
          {:ok, data}
        rescue
          _ -> {:error, :invalid_backup_format}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_backup(%{metadata: metadata, data: snapshot_data}) do
    Logger.info("Applying backup from #{metadata.timestamp}, #{metadata.entry_count} entries")

    # Clear current data
    :ets.delete_all_objects(:concord_store)

    # Insert backup data
    Enum.each(snapshot_data, fn {key, value} ->
      :ets.insert(:concord_store, {key, value})
    end)

    :telemetry.execute(
      [:concord, :backup, :restored],
      %{entry_count: metadata.entry_count},
      %{timestamp: metadata.timestamp, node: metadata.node}
    )

    :ok
  end

  defp get_backup_info(backup_path) do
    case read_backup(backup_path) do
      {:ok, %{metadata: metadata}} ->
        %{
          path: backup_path,
          timestamp: metadata.timestamp,
          size_bytes: File.stat!(backup_path).size,
          entry_count: metadata.entry_count,
          node: metadata.node,
          version: metadata.version
        }

      {:error, _} ->
        nil
    end
  end

  defp verify_checksum(%{metadata: metadata, data: data}) do
    expected = metadata.checksum
    actual = compute_checksum(data)

    if expected == actual do
      {:ok, :valid}
    else
      {:ok, :invalid}
    end
  end

  defp compute_checksum(data) do
    :crypto.hash(:sha256, :erlang.term_to_binary(data))
  end

  defp maybe_verify(_path, false), do: {:verify, {:ok, :valid}}
  defp maybe_verify(path, true), do: {:verify, verify(path)}
end
