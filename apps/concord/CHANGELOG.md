# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [3.0.0-beta.0] - 2026-07-19

### Added
- Add the standalone `viewstamped_replication` application and use it as
  Concord's replicated runtime.
- Publish `viewstamped_replication` 0.1.0 as Concord's protocol runtime
  dependency.
- Add three-node VSR release tests for KV, MVCC, transactions, leases, engine
  isolation, primary failover, and strong reads.

### Changed
- Rebuilt the changelog with the full published package release history.
- Make Viewstamped Replication the only replicated engine in Concord 3.0.
- Require explicit, ordered membership for multi-node VSR configurations.

### Removed
- Remove the Ra runtime, dependency, configuration switch, test harness, and
  operational scripts. Concord 3.0 does not read or migrate Ra storage.

### Fixed
- Align source package metadata and installation docs with the released 2.x API package.
- Document embedded boot fixes for Ra default system startup, Prometheus opt-in
  metrics, disabled clustering, and restart from existing Ra data directories.
  Fixes #17.

## [2.0.1] - 2026-05-30

### Fixed
- Start the Ra default system before Concord cluster initialization so embedded
  host applications do not need to start `:ra` manually.
- Return actionable backup errors when the Ra cluster is not available.
- Disable the Prometheus exporter by default so embedded hosts do not crash on
  metrics port conflicts.
- Add a `:clustering` switch so single-node embedded deployments can disable
  libcluster.
- Restart existing Ra servers from persisted data directories during app startup.

## [2.0.0] - 2026-05-16

### Added
- Add the v2 KV and transaction API, including `Concord.KV`,
  `Concord.Txn`, prefix/range listing, revision metadata, conditional
  operations, leases, and sync/watch support.
- Add v2 design documentation for MVCC records, transactions, sync/watch,
  leases, validation, and agent coordination.
- Add a release-mode E2E test suite for distributed node validation.

### Changed
- Move long-form documentation into versioned `docs/v1` and `docs/v2`
  directories.
- Update README and E2E documentation for the release-based architecture.
- Simplify the library surface around the embedded database use case.

### Removed
- Remove out-of-scope Web, AuditLog, EventStream, Tracing, and Prometheus
  modules and dependencies from the core library.

### Fixed
- Fix Ra 3.0 query calls and MFA query argument order.
- Fix CI, Credo, Dialyzer, ETS ownership, and release test data cleanup issues.

## [1.1.0] - 2026-03-23

### Changed
- Upgrade Ra and related dependency constraints for Ra 3.0 compatibility.

### Fixed
- Fix Ra 3.0 API usage in the state machine query path and test helper.
- Fix formatting and Credo issues before publishing the package.

## [1.0.2] - 2026-03-22

### Changed
- Optimize prefix scans from `O(N)` to `O(log N + K)`.

### Removed
- Remove token authentication, RBAC, and multitenancy from the embedded
  database surface.

### Fixed
- Fix ETS match specification formatting and remaining formatter violations.

## [1.0.1] - 2026-03-09

### Changed
- Reorganize the README into focused documentation guides.
- Add the Concord database skill and supporting API, HTTP, and state-machine
  references.

### Fixed
- Address review findings around correctness, deterministic replay, snapshot
  coverage, backup behavior, documentation, and tests.
- Improve E2E network partition coverage and test workflow behavior.

## [1.0.0] - 2025-12-09

### Added
- Add multi-node E2E coverage using manually spawned Erlang nodes.
- Add cluster connection helper scripts for manual distributed testing.
- Add Spec Kit command templates and project scaffolding.
- Improve the Hex.pm release workflow.

### Changed
- Make the HTTP API opt-in by default.
- Replace LocalCluster-based E2E tests with manual node spawning for OTP 28.
- Update development environment dependencies and project documentation.

### Fixed
- Fix distributed test startup and cleanup issues.
- Fix cluster restart handling when the Ra system is not started.
- Disable Prometheus metrics by default.
- Fix Dialyzer and CI release workflow issues.

## [0.3.0] - 2026-03-09

### Changed
- Publish a 0.x package line from the post-v1.0 cleanup state.
- Include the V3 deterministic state-machine work and documentation cleanup
  from the 1.0.x line.

### Removed
- Remove token authentication, RBAC, and multitenancy features from the 0.x
  package line.

## [0.2.0] - 2025-10-30

### Added
- Add TTL support, bulk operations, configurable read consistency, conditional
  updates, secondary indexes, and query filtering.
- Add backup/restore, value compression, performance benchmarks, and
  production configuration documentation.
- Add the HTTP API, OpenAPI documentation, TLS support, Mix tasks, and
  certificate generation.
- Add Prometheus metrics, OpenTelemetry tracing, audit logging, CDC event
  streaming, RBAC, and multitenancy features.

### Fixed
- Fix test isolation, ETS initialization, API response, TTL, bulk operation,
  Credo, Dialyzer, and CI issues discovered while hardening the feature set.

## [0.1.3] - 2025-10-18

### Added
- Initial embedded distributed key-value store built on Raft.
- Add ETS-backed reads, core CRUD operations, cluster startup, configuration,
  documentation, tests, CI, and release workflow scaffolding.

### Fixed
- Add required Hex.pm package metadata.
- Fix early formatting, lint, coverage, and release workflow failures.

[Unreleased]: https://github.com/gsmlg-dev/concord/compare/v3.0.0-beta.0...HEAD
[3.0.0-beta.0]: https://github.com/gsmlg-dev/concord/compare/v2.0.1...v3.0.0-beta.0
[2.0.1]: https://github.com/gsmlg-dev/concord/compare/v2.0.0...v2.0.1
[2.0.0]: https://github.com/gsmlg-dev/concord/compare/v1.1.0...v2.0.0
[1.1.0]: https://github.com/gsmlg-dev/concord/compare/v1.0.2...v1.1.0
[1.0.2]: https://github.com/gsmlg-dev/concord/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/gsmlg-dev/concord/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/gsmlg-dev/concord/compare/v0.2.0...v1.0.0
[0.3.0]: https://hex.pm/packages/concord/0.3.0
[0.2.0]: https://github.com/gsmlg-dev/concord/compare/v0.1.3...v0.2.0
[0.1.3]: https://github.com/gsmlg-dev/concord/releases/tag/v0.1.3
