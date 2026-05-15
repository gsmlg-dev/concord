# Backup and Restore

Comprehensive backup and restore for data safety and disaster recovery.

## Quick Start

### Create a Backup

```bash
# Default directory (./backups)
mix concord.backup create

# Custom directory
mix concord.backup create --path /mnt/backups
```

### List Backups

```bash
mix concord.backup list
```

### Restore from Backup

```bash
# Interactive (asks for confirmation)
mix concord.backup restore ./backups/concord_backup_20251023T143052.backup

# Force (skip confirmation)
mix concord.backup restore ./backups/concord_backup_20251023T143052.backup --force
```

### Verify Integrity

```bash
mix concord.backup verify ./backups/concord_backup_20251023T143052.backup
```

### Cleanup Old Backups

```bash
# Keep only 5 most recent
mix concord.backup cleanup --keep-count 5

# Keep backups from last 7 days
mix concord.backup cleanup --keep-days 7
```

## Programmatic API

```elixir
# Create backup
{:ok, backup_path} = Concord.Backup.create(path: "/mnt/backups")

# List backups
{:ok, backups} = Concord.Backup.list("/mnt/backups")
Enum.each(backups, fn backup ->
  IO.puts("#{backup.path} - #{backup.entry_count} entries")
end)

# Restore
:ok = Concord.Backup.restore("/mnt/backups/concord_backup_20251023.backup")

# Verify
case Concord.Backup.verify("/path/to/backup.backup") do
  {:ok, :valid} -> IO.puts("Backup is valid")
  {:ok, :invalid} -> IO.puts("Backup is corrupted")
  {:error, reason} -> IO.puts("Error: #{inspect(reason)}")
end

# Cleanup
{:ok, deleted_count} = Concord.Backup.cleanup(
  path: "/mnt/backups",
  keep_count: 10,
  keep_days: 30
)
```

## Backup Format

Backups are compressed Erlang term files (`.backup`) containing:

- **Metadata**: Timestamp, cluster info, entry count, checksum
- **Snapshot Data**: Full copy of all key-value pairs
- **Integrity Check**: SHA-256 checksum for verification

Features:
- Compressed storage for efficient disk usage
- Atomic snapshots via Ra consensus
- Compatible across cluster nodes

## Automated Backups

### Cron-based

```bash
# Backup every hour
0 * * * * cd /app && mix concord.backup create --path /mnt/backups

# Cleanup old backups daily
0 2 * * * cd /app && mix concord.backup cleanup --keep-count 24 --keep-days 7
```

### In-App Scheduler

```elixir
defmodule MyApp.BackupScheduler do
  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(state) do
    schedule_backup()
    {:ok, state}
  end

  def handle_info(:backup, state) do
    case Concord.Backup.create(path: "/mnt/backups") do
      {:ok, path} ->
        Logger.info("Backup created: #{path}")
        Concord.Backup.cleanup(path: "/mnt/backups", keep_count: 24)
      {:error, reason} ->
        Logger.error("Backup failed: #{inspect(reason)}")
    end

    schedule_backup()
    {:noreply, state}
  end

  defp schedule_backup do
    Process.send_after(self(), :backup, :timer.hours(1))
  end
end
```

## Disaster Recovery

```bash
# 1. Stop the application (if running)
# 2. Restore from backup
mix concord.backup restore /mnt/backups/latest.backup --force

# 3. Verify data
mix concord.cluster status

# 4. Start the application
mix run --no-halt
```

## Best Practices

1. **Regular Backups** — Schedule automated backups hourly or daily
2. **Off-site Storage** — Copy backups to remote storage (S3, GCS, etc.)
3. **Test Restores** — Periodically test backup restoration
4. **Retention Policy** — Keep multiple backup versions
5. **Monitor** — Set up alerts for backup failures
6. **Verify** — Always verify backups after creation
