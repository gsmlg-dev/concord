# Turso

[![CI](https://github.com/gsmlg-dev/concord/actions/workflows/ci.yml/badge.svg)](https://github.com/gsmlg-dev/concord/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/ex_turso.svg)](https://hex.pm/packages/ex_turso)

An Elixir library that wraps the [`turso`](https://crates.io/crates/turso) Rust
crate (v0.5) via [Rustler](https://github.com/rusterlium/rustler) NIFs, exposed
through a [`DBConnection`](https://hexdocs.pm/db_connection) pool.

It supports **local file databases** (and `":memory:"`), **Turso Cloud sync**
via embedded replicas, and turso's built-in **vector search** and **full-text
search** SQL features, with correct `ResourceArc` lifetime management and a
working connection pool. Ecto support is optional via `Ecto.Adapters.Turso`.

## Native binaries

Version 0.5 builds the NIF from source while its renamed `Turso.*` API is
prepared for a new set of precompiled artifacts. A working Rust toolchain
(`cargo`) matching the BEAM architecture is therefore required.

Future releases may provide precompiled binaries for:

| OS | Architectures |
| --- | --- |
| Linux | `aarch64`, `x86_64` |
| macOS | `aarch64`, `x86_64` |
| FreeBSD | `x86_64` |
| Windows | `x86_64` |

Releases also publish static NIF archives for static BEAM builds:

| Target | Archive |
| --- | --- |
| Linux amd64 musl | `ex_turso-vVERSION-static-x86_64-unknown-linux-musl.tar.gz` |
| Linux arm64 musl | `ex_turso-vVERSION-static-aarch64-unknown-linux-musl.tar.gz` |

Each archive contains `libex_turso.a`, which exports `ex_turso_nif_init` for
OTP's `ex_turso` static NIF library name. Use it when configuring OTP:

```sh
./configure --enable-static-nifs=/path/to/libex_turso.a:ex_turso
```

To build the archive from source instead:

```sh
TARGET=x86_64-unknown-linux-musl # or aarch64-unknown-linux-musl
rustup target add "$TARGET"
cargo build --manifest-path native/ex_turso/Cargo.toml \
  --target "$TARGET" \
  --release \
  --locked
nm -g --defined-only "native/ex_turso/target/$TARGET/release/libex_turso.a" \
  | grep ' ex_turso_nif_init$'
```

Use `cross build` instead of `cargo build` when building the arm64 musl archive
from a non-arm64 host.

## Installation

```elixir
def deps do
  [
    {:ex_turso, "~> 3.0.0-beta"}
  ]
end
```

## Usage

Start a pool under your supervision tree:

```elixir
children = [
  {Turso, database: "my_app.db", name: MyApp.DB}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

Then query and execute against the registered name:

```elixir
{:ok, _} = Turso.execute(MyApp.DB, "CREATE TABLE users (id INTEGER, name TEXT)")
{:ok, _} = Turso.execute(MyApp.DB, "INSERT INTO users VALUES (?, ?)", [1, "Alice"])

{:ok, %Turso.Result{rows: [%{"name" => "Alice"}]}} =
  Turso.query(MyApp.DB, "SELECT name FROM users WHERE id = ?", [1])
```

Transactions go through `DBConnection`:

```elixir
DBConnection.transaction(MyApp.DB, fn conn ->
  {:ok, _} = Turso.execute(conn, "UPDATE users SET name = ? WHERE id = ?", ["Bob", 1])
end)
```

Use `database: ":memory:"` for an in-memory database (one per pool connection).

Always pass values as bound parameters (`?`) rather than interpolating them
into the SQL string — statements are logged when a query errors.

## Ecto

`Turso` includes an optional SQL adapter for Ecto. Add `ecto_sql` in the
application that uses Ecto:

```elixir
def deps do
  [
    {:ex_turso, "~> 3.0.0-beta"},
    {:ecto_sql, "~> 3.14"}
  ]
end
```

Define your repo with `Ecto.Adapters.Turso`:

```elixir
defmodule MyApp.Repo do
  use Ecto.Repo,
    otp_app: :my_app,
    adapter: Ecto.Adapters.Turso
end
```

Configure it with the same database options used by `Turso`:

```elixir
config :my_app, MyApp.Repo,
  database: "my_app.db",
  pool_size: 5
```

The adapter supports regular `Ecto.Repo` schema/query operations and
`ecto_sql` migrations using Turso's SQLite-compatible SQL dialect. Streaming
and multi-result queries are not supported by the current native connection.

## Full-text search

Turso enables Turso's embedded full-text search index support for local
databases. Use Turso's FTS index syntax:

```elixir
{:ok, _} = Turso.execute(MyApp.DB, "CREATE TABLE docs (id INTEGER PRIMARY KEY, content TEXT)")
{:ok, _} = Turso.execute(MyApp.DB, "CREATE INDEX docs_fts ON docs USING fts (content)")

{:ok, %Turso.Result{rows: rows}} =
  Turso.query(MyApp.DB, "SELECT id FROM docs WHERE (content) MATCH ?", ["search term"])
```

SQLite's FTS5 virtual table syntax, such as
`CREATE VIRTUAL TABLE docs_fts USING fts5(content)`, is not exposed by the
embedded `turso` crate v0.5 API. Use `CREATE INDEX ... USING fts` with `MATCH`
queries instead.

## Turso Cloud sync

Pass `:remote_url` and `:auth_token` to open the local file as an embedded
replica of a Turso Cloud database:

```elixir
children = [
  {Turso,
   database: "replica.db",
   remote_url: "libsql://my-db.turso.io",
   auth_token: fn -> System.fetch_env!("TURSO_AUTH_TOKEN") end,
   name: MyApp.DB}
]
```

`auth_token` accepts a string or a zero-arity function; prefer the function so
the token does not appear in supervisor child specs and crash reports.

Trigger a bidirectional sync (pull then push) with:

```elixir
:ok = Turso.sync(MyApp.DB)
```

Sync is rejected inside a transaction and on databases not configured with
`:remote_url`/`:auth_token`.

## Errors

Failures return `{:error, %Turso.Error{message: message, code: code}}`. The
`code` classifies the failure: `:busy` (locked, retryable), `:constraint`,
`:invalid_param` (unsupported bound parameter type), `:misuse`, `:error`, or
`:io`/`:corrupt` — the last two mark the connection as broken, so the pool
drops it and opens a fresh one.

## Architecture

| Layer | Module / file | Role |
| --- | --- | --- |
| Native | `native/ex_turso/src/lib.rs` | Rustler NIFs over `turso`, driven by a global Tokio runtime |
| NIF decls | `Turso.Native` | Loads the compiled NIF |
| Pooling | `Turso.Connection` | `DBConnection` behaviour implementation |
| Query | `Turso.Query` | Statement struct + `DBConnection.Query` protocol |
| Ecto | `Ecto.Adapters.Turso` | Optional `ecto_sql` adapter |
| Public API | `Turso` | `start_link/1`, `child_spec/1`, `query/3`, `execute/3` |
