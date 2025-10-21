# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2025-10-22

### Added
- Distributed key-value store built on Raft consensus algorithm
- High-performance embedded database for Elixir applications
- Core CRUD operations (put, get, delete) with strong consistency
- TTL (Time-To-Live) support for automatic data expiration
- Bulk operations (put_many, get_many, delete_many, touch_many)
- Token-based authentication system with secure crypto
- Comprehensive telemetry and observability
- HTTP REST API with full feature parity
  - Authentication via Bearer tokens and API keys
  - Complete CRUD operations
  - Bulk operations endpoints
  - TTL management endpoints
  - Health checks and monitoring
  - OpenAPI 3.0 specification and Swagger UI
- Performance benchmark suite showing 600K-870K ops/sec
- Memory-efficient storage (~10 bytes per item overhead)
- Automatic cluster discovery via libcluster
- Production-ready configuration options
- Comprehensive documentation and performance analysis

### Performance
- Core KV operations: 600K-870K ops/sec
- Microsecond-level latency (1-7μs)
- HTTP API: 5K+ requests/second for health checks
- Memory efficiency: ~10 bytes per stored item
- TTL operations: Near-zero overhead

### Documentation
- Complete README with embedded database focus
- API design documentation
- Performance analysis and benchmark results
- OpenAPI specification
- Example usage patterns for embedded applications