# Concord

[![GitHub release](https://img.shields.io/github/v/release/gsmlg-dev/concord?include_prereleases&sort=semver)](https://github.com/gsmlg-dev/concord/releases)
[![CI](https://github.com/gsmlg-dev/concord/actions/workflows/ci.yml/badge.svg)](https://github.com/gsmlg-dev/concord/actions/workflows/ci.yml)

Concord is an Elixir umbrella project for building embedded, strongly
consistent data services with Viewstamped Replication.

## Packages

| Package | Description | Hex.pm |
| --- | --- | --- |
| [`concord`](apps/concord) | Distributed, strongly consistent embedded key-value store | [![Concord on Hex.pm](https://img.shields.io/hexpm/v/concord.svg?label=concord)](https://hex.pm/packages/concord) |
| [`ex_turso`](apps/ex_turso) | DBConnection-backed Elixir wrapper for Turso/libSQL via Rustler | [![ExTurso on Hex.pm](https://img.shields.io/hexpm/v/ex_turso.svg?label=ex_turso)](https://hex.pm/packages/ex_turso) |
| [`viewstamped_replication`](apps/viewstamped_replication) | Protocol-generic Viewstamped Replication runtime for Elixir | [![Viewstamped Replication on Hex.pm](https://img.shields.io/hexpm/v/viewstamped_replication.svg?label=viewstamped_replication)](https://hex.pm/packages/viewstamped_replication) |

See each package's README for installation, configuration, and usage.

## Development

```sh
mix deps.get
mix test
```

## License

MIT
