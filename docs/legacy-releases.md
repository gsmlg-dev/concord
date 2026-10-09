# Legacy compatibility releases

Concord 2.4.1 and ExTurso 0.3.2 preserve the published Concord 2.x and
`ExTurso.*` APIs. Concord requires `ex_turso ~> 0.3.2`, excluding the incompatible
0.5 and 3.x APIs. These versions also satisfy WHOIS 0.5.1's existing requirements.
Current Concord 3.x uses VSR and the `Turso.*` API and is released separately.

`scripts/prepare_legacy_packages.sh OUTPUT_DIRECTORY` prepares these patches
from the immutable Hex tarballs for Concord 2.4.0 and ExTurso 0.3.1. The script
verifies their pinned SHA-256 checksums before extracting them, preserves the
API implementations, and checks the patched dependency range. It stages an
empty NIF checksum map; the release workflow replaces it with all eight real
artifact checksums before package validation or publication.

Run the compatibility release from `main`:

```sh
gh workflow run release-legacy.yml --repo gsmlg-dev/concord --ref main
```

The native source implementation is unchanged. The workflow verifies the six
existing binaries against the pinned 0.3.1 checksum map and repackages their
unchanged bytes under the new version, preserving their platform ABI. It adds
native Alpine amd64 and arm64 builds with dynamic C TLS so mimalloc can load as
a shared NIF. It checks fresh WHOIS consumers and database reopen behavior on
both Alpine architectures without Rust, then publishes the NIF
assets and checksum-bearing Hex packages. A final check installs the published
packages and downloads their NIFs from the public release URLs without local
package or artifact overrides.

Legacy GitHub tags identify the workflow and patch instructions on `main`.
The accompanying `concord-2.4.1.tar` and `ex_turso-0.3.2.tar` assets contain the
actual patched legacy package sources; the repository tree at those tags is
the current umbrella. Keep the current umbrella on its normal version sequence.
