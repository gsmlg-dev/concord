#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 OUTPUT_DIRECTORY" >&2
  exit 1
fi

# Preserve the published 2.x/ExTurso APIs independently of the current umbrella.
# SHA-256 values are the immutable outer checksums from the Hex release API.
python3 - "$1" <<'PY'
import hashlib
import io
from pathlib import Path
import tarfile
import urllib.request
import sys

output = Path(sys.argv[1]).resolve()
sources = [
    ("concord", "2.4.0", "138153efa42ea17e60484886abaa7244012716f99075ce15d526f5ffb1a4a033"),
    ("ex_turso", "0.3.1", "7ebc443e44b9421035c7775af017ffc2b01b5fb58b77eb7fb824d73424149bf6"),
]

for package, _, _ in sources:
    if (output / package).exists():
        raise SystemExit(f"Refusing to overwrite {output / package}")

for package, version, checksum in sources:
    url = f"https://repo.hex.pm/tarballs/{package}-{version}.tar"
    with urllib.request.urlopen(url, timeout=60) as response:
        archive = response.read()
    if hashlib.sha256(archive).hexdigest() != checksum:
        raise SystemExit(f"Hex checksum mismatch for {package} {version}")
    with tarfile.open(fileobj=io.BytesIO(archive)) as outer:
        contents = outer.extractfile("contents.tar.gz").read()
    with tarfile.open(fileobj=io.BytesIO(contents), mode="r:gz") as inner:
        inner.extractall(output / package, filter="data")


def replace_exact(path, old, new, count=1):
    text = path.read_text()
    if text.count(old) != count:
        raise SystemExit(f"Expected {count} occurrence(s) of {old!r} in {path}")
    path.write_text(text.replace(old, new, count))


concord = output / "concord"
turso = output / "ex_turso"
replace_exact(concord / "mix.exs", 'version: "2.4.0"', 'version: "2.4.1"')
replace_exact(concord / "mix.exs", '{:ex_turso, "~> 0.3"}', '{:ex_turso, "~> 0.3.2"}')
replace_exact(concord / "README.md", '{:concord, "~> 2.0"}', '{:concord, "~> 2.4.1"}')
replace_exact(concord / "README.md", '{:concord, "~> 2.3"}', '{:concord, "~> 2.4.1"}')
replace_exact(concord / "README.md", '{:ex_turso, "~> 0.3"}', '{:ex_turso, "~> 0.3.2"}')
replace_exact(turso / "mix.exs", 'version: "0.3.1"', 'version: "0.3.2"')
replace_exact(
    turso / "mix.exs",
    'https://github.com/gsmlg-dev/ex_turso',
    'https://github.com/gsmlg-dev/concord/tree/main/apps/ex_turso',
)
replace_exact(
    turso / "README.md",
    'https://github.com/gsmlg-dev/ex_turso/actions/workflows/ci.yml',
    'https://github.com/gsmlg-dev/concord/actions/workflows/ci.yml',
    count=2,
)
replace_exact(turso / "README.md", '{:ex_turso, "~> 0.2.0"}', '{:ex_turso, "~> 0.3.2"}', count=2)
replace_exact(turso / "README.md", '| Linux |', '| Linux (glibc and musl) |')
replace_exact(
    turso / "README.md",
    '## Installation\n',
    'Alpine source builds also require dynamic CRT and C thread-local storage:\n\n'
    '```sh\n'
    'export RUSTFLAGS="-C target-feature=-crt-static"\n'
    'export CFLAGS="-ftls-model=local-dynamic"\n'
    '```\n\n'
    '## Installation\n',
)
replace_exact(turso / "native/ex_turso/Cargo.toml", 'version = "0.3.1"', 'version = "0.3.2"')
replace_exact(
    turso / "native/ex_turso/Cargo.lock",
    'name = "ex_turso"\nversion = "0.3.1"',
    'name = "ex_turso"\nversion = "0.3.2"',
)
native = turso / "lib/ex_turso/native.ex"
replace_exact(
    native,
    'https://github.com/gsmlg-dev/ex_turso/releases/download/v#{version}',
    'https://github.com/gsmlg-dev/concord/releases/download/v#{version}',
)
for architecture in ["aarch64", "x86_64"]:
    target = f"      {architecture}-unknown-linux-gnu\n"
    replace_exact(native, target, target + f"      {architecture}-unknown-linux-musl\n")

# Regenerate checksums from the 0.3.2 release assets before publishing this package.
checksum_file = turso / "checksum-Elixir.ExTurso.Native.exs"
(output / "baseline-nif-checksums.exs").write_bytes(checksum_file.read_bytes())
checksum_file.write_text("%{}\n")
print(f"Prepared Concord 2.4.1 at {concord}")
print(f"Prepared ExTurso 0.3.2 at {turso}")
PY

# Check the real generated dependency declaration, not a duplicate test constant.
elixir -e '
Mix.start()
Code.compile_file(Path.join(hd(System.argv()), "concord/mix.exs"))
project = Concord.MixProject.project()
"2.4.1" = project[:version]
{:ex_turso, requirement} = List.keyfind(project[:deps], :ex_turso, 0)
true = Version.match?("0.3.2", requirement)
true = Version.match?("0.3.99", requirement)
false = Version.match?("0.3.1", requirement)
false = Version.match?("0.4.0", requirement)
false = Version.match?("0.5.0", requirement)
false = Version.match?("3.0.6", requirement)
Code.compile_file(Path.join(hd(System.argv()), "ex_turso/mix.exs"))
"0.3.2" = ExTurso.MixProject.project()[:version]
IO.puts("Legacy dependency compatibility checks passed")
' "$1"
