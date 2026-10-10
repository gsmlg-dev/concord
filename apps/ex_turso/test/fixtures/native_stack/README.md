# Native stack regression fixtures

These fixtures reproduce [Concord #90](https://github.com/gsmlg-dev/concord/issues/90).
The balanced SQL preserves the exact evidence CHECK from Fornacast migration
`20260825000430_add_import_cleanup_recovery.exs` at commit
`3ef5e4ae05dee0817f81b3f888f79db00fdd8ea2`:

https://github.com/gsmlg-opt/Fornacast/blob/3ef5e4ae05dee0817f81b3f888f79db00fdd8ea2/apps/fornacast/priv/repo/migrations/20260825000430_add_import_cleanup_recovery.exs

The seven-column `cleanup` table isolates the CHECK from unrelated foreign
keys and migrations. Five generated AND lists have balanced, ordered
parentheses instead of flat joins; predicates are retained. Keep the exact
expression rather than a smaller generated approximation: parser acceptance
alone did not expose the native crash, which occurred on the first insert.

The JSON contains synthetic witnesses modeled on the same revision's
migration tests: all three valid evidence kinds, and seven invalid cases
(unknown key, numeric string, remote mode, fingerprint, partial anchor,
replacement authority drift, and missing required key). IDs, paths and
fingerprints are synthetic test data.

Fornacast did not declare a repository licence at that revision. These
test-only fixtures retain the source attribution and are excluded from the
Hex package.

The subprocess reuses the suite's compiled code paths without invoking Mix
or rebuilding the NIF. Erlang/Elixir option environment variables are cleared
so the dirty IO scheduler uses its default stack size. A native crash must
produce a failed subprocess exit, and successful assertions must print the
explicit completion marker. The probe checks execute, both native query
result formats, constraint rejection, and persisted rows after close/reopen.
