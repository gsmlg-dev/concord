# Repository Guidelines

## Project Structure & Module Organization

Concord is a three-app Elixir umbrella. `apps/concord/lib/` contains the database APIs and deterministic state machine. `apps/viewstamped_replication/lib/` implements the VSR protocol and runtime. `apps/ex_turso/lib/` wraps Turso/libSQL; its Rustler NIF lives in `apps/ex_turso/native/ex_turso/`.

Tests mirror each app under `apps/*/test/`. Shared configuration is in `config/`, release-cluster tests in `e2e_test/`, and documentation in `docs/`. OpenAPI and dashboard artifacts live at the root and in `apps/concord/priv/`.

Keep replicated behavior deterministic in `Concord.StateMachine.Core`; route replicated mutations through `Concord.Engine.command/2`.

## Build, Test, and Development Commands

Use Elixir 1.18, OTP 28, stable Rust, `pkg-config`, and OpenSSL headers.

- `mix deps.get` installs umbrella dependencies.
- `mix compile --warnings-as-errors` runs the CI compile gate.
- `iex -S mix` starts an interactive development shell.
- `mix test` runs all application tests.
- `mix do --app concord cmd mix test test/concord/validation_test.exs` runs one scoped test file.
- `mix format --check-formatted`, `mix credo --strict`, and `mix do --app concord cmd mix dialyzer` run quality checks.
- `./e2e_test/scripts/run_e2e.sh` builds a release and exercises a real three-node VSR cluster.

## Coding Style & Naming Conventions

Run `mix format` before submitting changes; accept its two-space indentation and layout. Use `CamelCase` module names, `snake_case` files and functions, and `?` suffixes for predicates. Namespace paths must match modules. Credo enforces a 120-character line limit. Format and lint native Rust with `cargo fmt` and `cargo clippy`.

## Testing Guidelines

Tests use ExUnit and are named `*_test.exs`; test modules end in `Test`. Concord integration tests are usually `async: false` because registered VSR processes and ETS tables are shared. Coverage thresholds are 50% for Concord, 80% for VSR, and 25% for ExTurso. Add Core unit and public API integration coverage for replicated features; add E2E coverage for distribution or failover behavior.

## Commit & Pull Request Guidelines

Follow Conventional Commits, optionally scoped: `feat(vsr): ...`, `fix(release): ...`, `docs: ...`, `test: ...`, `refactor: ...`, or `chore: ...`. Keep commits focused and omit generated-by or co-author trailers.

Target PRs to `main`. Include a concise summary, validation commands and results, and `Fixes #N` when applicable. Call out protocol, persistence, migration, or failover impact. Ensure compile, format, Credo, Dialyzer, Rust, coverage, package, and E2E checks pass.

## Configuration & Security

Keep tokens, keys, certificates, and `.env` files out of Git. Supply secrets through runtime environment variables. Every replica must receive the same ordered VSR membership; use bootstrap mode only with fresh, empty storage.
