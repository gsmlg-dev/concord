# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Concord is a distributed, strongly-consistent key-value store built in Elixir using the Raft consensus algorithm. It's a CP (Consistent + Partition-tolerant) system that provides distributed coordination, configuration management, and service discovery capabilities.

## Development Commands

### Building and Testing
```bash
# Run all tests
mix test

# Run specific test file
mix test test/concord_test.exs

# Run with coverage
mix test --cover

# Run linting
mix credo

# Run type checking
mix dialyzer
```

### Cluster Management
```bash
# Start multiple nodes (separate terminals)
iex --name n1@127.0.0.1 --cookie secret -S mix
iex --name n2@127.0.0.1 --cookie secret -S mix
iex --name n3@127.0.0.1 --cookie secret -S mix

# Check cluster status
mix concord.cluster status

# List cluster members
mix concord.cluster members

# Create authentication token
mix concord.cluster token create

# Revoke a token
mix concord.cluster token revoke <token>
```

### Testing with Multiple Nodes
The test suite is configured with `--no-start` alias to avoid automatic cluster startup, allowing proper multi-node testing scenarios.

### Code Quality
- **Linting**: Credo is configured with a custom ruleset in `.credo.exs` with max line length of 120
- **Type Checking**: Dialyzer is configured for static analysis with PLT files in `plts/dialyzer.plt`
- **Coverage**: Test coverage threshold is set to 40% with detailed summaries

## Architecture Overview

### Core Components
- **Concord.Application** - Main application supervisor that starts cluster components
- **Concord.StateMachine** - Raft state machine implementing the distributed KV store using ETS
- **Concord.Auth** - Authentication system with token-based access control
- **Concord.Telemetry** - Comprehensive metrics and observability
- **Mix.Tasks.Concord.Cluster** - Command-line cluster management tools

### Key Dependencies
- **ra** - Raft consensus algorithm implementation
- **libcluster** - Automatic node discovery via gossip protocol
- **telemetry** - Metrics and observability framework
- **jason** - JSON serialization for data storage
- **plug_crypto** - Cryptographic utilities for secure token generation

### Data Flow
1. **Write Operations**: Client API → Auth verification → Raft leader → Quorum replication → State machine → ETS storage
2. **Read Operations**: Client API → Auth verification → Leader query → Direct ETS lookup
3. **Cluster Management**: libcluster gossip → Automatic node discovery → Raft cluster membership

### State Machine Details
The `Concord.StateMachine` implements the `:ra_machine` behavior and uses:
- ETS table `:concord_store` for in-memory storage
- Telemetry events for all operations
- Snapshot support for recovery
- Query functions for reads (bypass Raft log for performance)

### Authentication System
- Token-based authentication using secure crypto
- ETS-based token store for fast lookups
- Per-environment configuration
- Token creation and revocation operations

## Configuration

The configuration follows standard Elixir patterns with environment-specific files:
- `config/config.exs` - Base configuration with cluster name and libcluster topology
- `config/dev.exs` - Development settings with auth disabled and local data directory
- `config/test.exs` - Test configuration with `--no-start` alias for multi-node testing
- `config/prod.exs` - Production settings with auth enabled and environment variables
- `config/runtime.exs` - Runtime configuration loaded at startup

### Development (config/dev.exs)
- Auth disabled by default
- Local data directory: `./data/dev`
- Debug logging enabled

### Production (config/prod.exs)
- Auth enabled by default
- Environment variable configuration
- Info logging level

## Testing Strategy

Test categories:
- **Unit Tests**: Basic CRUD operations, validation
- **Auth Tests**: Token management, authorization flows
- **Telemetry Tests**: Event emission verification
- **Integration Tests**: Multi-node scenarios

The test suite uses ExUnit with the `--no-start` mix alias to prevent automatic cluster startup during testing.

## Operational Notes

### Performance Characteristics
- **Writes**: ~5-20ms (requires quorum)
- **Reads**: ~1-5ms (leader query + ETS lookup)
- **Storage**: In-memory only (limited by RAM)
- **Keys**: Max 1024 bytes
- **Values**: No hard limit (consider memory usage)

### Common Troubleshooting
- Check Erlang cookie consistency across nodes
- Verify network connectivity between nodes
- Monitor Raft commit index for cluster health
- Track leader changes via telemetry events

### Important File Locations
- Raft logs and snapshots: `{data_dir}/`
- ETS table: Named `:concord_store`
- Telemetry events: `[:concord, :api, :*]`, `[:concord, :operation, :*]`, `[:concord, :state, :*]`
- Cluster management tasks: `lib/mix/tasks/concord.ex`