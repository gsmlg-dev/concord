defmodule Concord.Turso do
  @moduledoc """
  Explicit Turso-backed Concord API.

  This API uses a local Turso database through `ex_turso`. It is durable and
  node-local: it does not submit writes to the VSR cluster and it does not
  replicate data to Concord cluster peers.

  Point, metadata and batch reads carry one finite timeout through readiness,
  connection acquisition and SQL. Batch reads share that budget across all keys
  and stop before subsequent SQL after expiry. Public value and metadata getters
  also check the budget around decompression. Expiry returns `{:error, :timeout}`;
  native work and decoding already in progress cannot be forcibly interrupted,
  so the response may arrive after the timeout.

  For a sequence of calls, calculate the caller's remaining timeout before each
  call. For example, pass that remaining value to
  `Concord.KV.get(key, engine: :turso, metadata: true, timeout: remaining_ms)` and
  recalculate it before a later `compare_and_swap/3`. These remain separate
  operations; use `mod_revision` to fence the write. Absolute deadlines are an
  internal implementation detail, not a required public read option.
  """

  alias Concord.{APIOptions, Deadline, Engine}
  alias Concord.Turso.PrefixReplacement
  alias Elixir.Turso, as: TursoClient

  @db __MODULE__.DB

  @doc false
  def child_spec(opts) do
    opts = Keyword.merge(pool_options(), opts)
    TursoClient.child_spec(opts)
  end

  @doc false
  def enabled? do
    config() |> Keyword.get(:enabled, false)
  end

  @doc false
  def pool_options do
    config = config()
    database = Keyword.get(config, :database, default_database())

    if database != ":memory:" do
      database |> Path.dirname() |> File.mkdir_p!()
    end

    [
      database: database,
      name: @db,
      pool_size: Keyword.get(config, :pool_size, 1)
    ]
    |> maybe_put(:remote_url, Keyword.get(config, :remote_url))
    |> maybe_put(:auth_token, Keyword.get(config, :auth_token))
  end

  def put(key, value, opts \\ []), do: Concord.put(key, value, APIOptions.turso(opts))
  def get(key, opts \\ []), do: Concord.get(key, APIOptions.turso(opts))
  def delete(key, opts \\ []), do: Concord.delete(key, APIOptions.turso(opts))
  def put_if(key, value, opts), do: Concord.put_if(key, value, APIOptions.turso(opts))

  @doc "See `Concord.KV.compare_and_swap/3`."
  def compare_and_swap(key, value, opts \\ []),
    do: Concord.compare_and_swap(key, value, APIOptions.turso(opts))

  def delete_if(key, opts), do: Concord.delete_if(key, APIOptions.turso(opts))
  def get_all(opts \\ []), do: Concord.get_all(APIOptions.turso(opts))
  def status(opts \\ []), do: Concord.status(APIOptions.turso(opts))
  def members(opts \\ []), do: Concord.members(APIOptions.turso(opts))

  def put_with_ttl(key, value, ttl_seconds, opts \\ []) do
    Concord.put_with_ttl(key, value, ttl_seconds, APIOptions.turso(opts))
  end

  def touch(key, additional_ttl_seconds, opts \\ []) do
    Concord.touch(key, additional_ttl_seconds, APIOptions.turso(opts))
  end

  def ttl(key, opts \\ []), do: Concord.ttl(key, APIOptions.turso(opts))
  def get_with_ttl(key, opts \\ []), do: Concord.get_with_ttl(key, APIOptions.turso(opts))
  def get_all_with_ttl(opts \\ []), do: Concord.get_all_with_ttl(APIOptions.turso(opts))
  def prefix_scan(prefix, opts \\ []), do: Concord.prefix_scan(prefix, APIOptions.turso(opts))
  def put_many(operations, opts \\ []), do: Concord.put_many(operations, APIOptions.turso(opts))

  @doc """
  Atomically replaces a prefix and publishes the supplied key-value pairs.

  Removes current records whose keys start with the nonempty binary `prefix`,
  then writes every `{key, value}` pair in one Turso commit. Puts may include
  related metadata keys outside the removed prefix. Keys must be unique; an
  empty put list deletes the prefix without writing replacements.

  ## Options

  - `:compare` — pre-commit predicates using the `Concord.Txn` compare grammar
    (default: `[]`). Every predicate observes the state before replacement.
  - `:compress` — optional value compression, as with `Concord.KV.put/3`.
  - `:timeout` — one operation budget in milliseconds (default: 5000), or
    `:infinity`, covering validation, compression, acquisition, readiness and SQL.

  The put bound is 501 pairs total, allowing 500 replacement rows plus one
  related metadata row in the same publication. Generic batch APIs remain capped
  at 500 pairs. There is a 16 MiB logical and encoded value limit and
  a 64 MiB logical and encoded command limit, including predicates and keys.
  Lower configured admission limits still apply, including `:max_batch_size`;
  an explicit cap of 500 must be raised to 501 to admit the additional pair.
  Predicates retain transaction
  compare limits; replacement values do not use the generic 128-operation,
  1,000,000-byte transaction envelope. This API has no per-pair TTL or lease opts.

  Returns `{:ok, %{succeeded: boolean, revision: revision, deleted: count,
  written: count}}`. A failed comparison returns `succeeded: false` without
  mutation. Successful publication shares one revision, so historical readers
  observe complete before/after replacement rather than an intermediate delete.

  Native work cannot be forcibly interrupted. Expiry before commit rolls back;
  a native commit already in progress can finish after the deadline, and a known
  successful acknowledgement is preserved. There is no idempotency receipt for
  this operation: reconcile an uncertain outcome before retrying. Calls always
  use the node-local Turso engine, independently of any `:engine` option.

      Concord.Turso.replace_prefix("turns/session/", [
        {"turns/session/001", %{text: "new transcript"}},
        {"sessions/session", %{title: "Updated"}}
      ], compare: [{:mod_revision, "sessions/session", :==, observed_revision}])
  """
  @spec replace_prefix(binary(), [{binary(), term()}], keyword()) ::
          {:ok,
           %{
             succeeded: boolean(),
             revision: non_neg_integer(),
             deleted: non_neg_integer(),
             written: non_neg_integer()
           }}
          | {:error, term()}
  def replace_prefix(prefix, puts, opts \\ []) do
    opts = opts |> APIOptions.turso() |> Deadline.start()

    with {:ok, command} <- PrefixReplacement.prepare(prefix, puts, opts),
         :ok <- Deadline.check(opts) do
      Engine.command(command, opts)
    end
  end

  def put_many_with_ttl(operations, ttl_seconds, opts \\ []) do
    Concord.put_many_with_ttl(operations, ttl_seconds, APIOptions.turso(opts))
  end

  def get_many(keys, opts \\ []), do: Concord.get_many(keys, APIOptions.turso(opts))
  def delete_many(keys, opts \\ []), do: Concord.delete_many(keys, APIOptions.turso(opts))

  def touch_many(operations, opts \\ []),
    do: Concord.touch_many(operations, APIOptions.turso(opts))

  def revision(opts \\ []), do: Concord.revision(APIOptions.turso(opts))

  @doc """
  Lists current or historical records in lexical prefix or range order.

  Use `order: :desc` for descending keys; ascending order is the default. Continue
  descending pages with `range: {original_start, last_key}` and the same order.

  Set `:revision` to a nonnegative committed revision for a snapshot page, and
  retain it on every continuation page. Revision `0` is empty; revisions ahead
  of the current committed revision return `{:error, :future_revision}`, and
  malformed revisions return `{:error, :invalid_revision}`. Later overwrites,
  appends and deletions do not change an earlier snapshot. TTL visibility uses
  the current wall clock, rather than a historical wall-clock timestamp.
  History is retained without automatic compaction for the database's lifetime.
  Versions discarded by pre-3.1.12 `touch` operations cannot be reconstructed.
  Such old snapshots use retained point-read history without a separate
  availability marker; capture revisions after upgrading all writers for
  complete snapshots. Replacing/resetting the database invalidates old revisions.

  Historical lists return snapshot Records. A historical `Concord.KV.get/2`
  returns the selected value, even with `metadata: true`, because a non-nil
  `:revision` takes precedence. To read metadata and selected values separately,
  use a key-only list and point reads at the same revision.

  Accepts the selector, limit, cursor continuation, and timeout options described
  by `Concord.KV.list/1`. With `keys_only: true`, the SQL query reads a covering
  index containing keys and value-free record metadata. Stored values are neither
  fetched nor decoded after database readiness completes. Application metadata is
  preserved, so its size still contributes to read and index costs.

  Database readiness adds value-free projections for current and historical
  records, including `concord_turso_history.record_metadata`, and byte-seek
  indexes. Backfilling missing metadata reads and decodes the corresponding
  original records, preserving their record/history bytes and revision counters.
  The projections and indexes add storage and write costs. Plan an upgrade
  window for large stores; before serving requests, a call such as
  `list(prefix: "", limit: 1, keys_only: true, timeout: :infinity)` can finish
  readiness without a finite operation deadline. Legacy writers, including
  3.1.11, can omit the new projection through `INSERT OR REPLACE`; readiness
  repairs missing metadata before the next engine operation.

  By default, list calls return `{:error, :timeout}` immediately when the pool is
  busy, including with the default timeout or `:infinity`. Use `queue: true` with
  a finite positive `:timeout` to wait for brief contention. One deadline covers
  admission, connection acquisition, readiness and querying. Invalid queue choices
  return `:invalid_queue`; infinite or nonpositive queued timeouts return
  `:invalid_queue_timeout`.

  Waiting and running queued lists share a finite capacity (default 64), configured
  with `:list_queue_capacity` in the `:turso` application configuration. Full
  capacity returns `{:error, :overloaded}`. Caller exit releases waiting admission;
  already running native work retains capacity until cleanup finishes. Synchronous
  native database work cannot be forcibly interrupted. Both value and key-only pages filter
  expired/deleted rows before applying the limit and continuation lookahead.
  """
  def list(opts), do: Concord.list(APIOptions.turso(opts))

  @doc """
  Commits an atomic transaction using the options described by `Concord.Txn.commit/2`.

  A finite timeout is one budget shared by connection acquisition, database
  readiness, statements, and the commit. Brief pool contention can wait within
  that budget. If readiness exhausts it, the application transaction does not run;
  expiry during its body rolls the transaction back before commit.

  Synchronous native work cannot be forcibly interrupted. A native commit already
  in progress may finish after the deadline; its successful acknowledgement is
  preserved. `timeout: :infinity` keeps unbounded acquisition and execution.
  Once a native commit starts, timeout alone is not proof of no effect; resolve
  an idempotent transaction receipt or reconcile stored state before retrying.
  """
  def txn(spec, opts \\ []), do: Concord.txn(spec, APIOptions.turso(opts))

  @doc """
  Synchronizes the local Turso database with a configured remote database.
  """
  def sync(opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)

    case Process.whereis(@db) do
      nil -> {:error, :engine_not_started}
      _pid -> TursoClient.sync(@db, timeout: timeout)
    end
  end

  defp config do
    Application.get_env(:concord, :turso, [])
  end

  defp default_database do
    Application.get_env(:concord, :data_dir, "./data")
    |> Path.join("turso.db")
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
