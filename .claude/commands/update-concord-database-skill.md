Perform a fresh, comprehensive analysis of the Concord project and update the concord-database skill at `skills/concord-database/`.

## Analysis Steps

1. **Read all source files** to capture the current state of the codebase:
   - `lib/concord.ex` — All public API functions, options, return types
   - `lib/concord/state_machine.ex` — All commands, queries, state shape, snapshot logic
   - `lib/concord/auth.ex` — Auth API
   - `lib/concord/rbac.ex` — RBAC API
   - `lib/concord/multi_tenancy.ex` — Multi-tenancy API
   - `lib/concord/index.ex` and `lib/concord/index/extractor.ex` — Index API and extractor specs
   - `lib/concord/backup.ex` — Backup/restore API
   - `lib/concord/ttl.ex` — TTL management
   - `lib/concord/query.ex` — Query language API
   - `lib/concord/event_stream.ex` — Event streaming API
   - `lib/concord/compression.ex` — Compression API
   - `lib/concord/web/router.ex` and `lib/concord/web/authenticated_router.ex` — HTTP routes
   - `lib/concord/web/api_controller.ex` — HTTP handler details
   - `lib/concord/application.ex` — Supervisor tree
   - `config/config.exs` — All configuration options
   - `config/runtime.exs` — Runtime configuration
   - `CLAUDE.md` — Correctness invariants and architecture
   - `mix.exs` — Dependencies and aliases

2. **Compare with current skill** — Read existing skill files:
   - `skills/concord-database/SKILL.md`
   - `skills/concord-database/references/api-reference.md`
   - `skills/concord-database/references/state-machine.md`
   - `skills/concord-database/references/http-api.md`

3. **Update all skill files** to reflect any changes:
   - New/removed/changed API functions
   - New/changed state machine commands or queries
   - New/changed HTTP endpoints
   - Updated configuration options
   - New modules or features
   - Updated correctness invariants
   - Changed testing patterns

## Guidelines

- Keep SKILL.md concise (<500 lines) — it shares context window space
- Use imperative/infinitive form in instructions
- Include only information an AI agent wouldn't already know
- Ensure all code examples match actual source code signatures
- Verify correctness invariants still match CLAUDE.md
- Update references/ files with detailed information
- Do NOT create README.md or other auxiliary files
