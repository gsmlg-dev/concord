#!/usr/bin/env python3
"""Preserve the unchanged native implementation and its existing platform ABI."""

import gzip
import hashlib
import io
from pathlib import Path
import re
import sys
import tarfile
import urllib.request

checksums = Path(sys.argv[1]).read_text()
output = Path(sys.argv[2])
output.mkdir(parents=True, exist_ok=True)
entries = re.findall(r'"([^"]+)"\s*=>\s*"sha256:([0-9a-f]{64})"', checksums)
if len(entries) != 6:
    raise SystemExit("Expected all six immutable ExTurso 0.3.1 NIF checksums")

for name, checksum in entries:
    if "-v0.3.1-nif-2.15-" not in name:
        raise SystemExit(f"Unexpected baseline NIF name: {name}")
    url = "https://github.com/gsmlg-dev/ex_turso/releases/download/v0.3.1/" + name
    with urllib.request.urlopen(url, timeout=60) as response:
        archive = response.read()
    if hashlib.sha256(archive).hexdigest() != checksum:
        raise SystemExit(f"Baseline NIF checksum mismatch: {name}")
    library_name = name.removesuffix(".tar.gz")
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as original:
        members = original.getmembers()
        if len(members) != 1 or members[0].name != library_name or not members[0].isfile():
            raise SystemExit(f"Unexpected NIF archive contents: {name}")
        library = original.extractfile(members[0]).read()
    new_name = name.replace("-v0.3.1-", "-v0.3.2-")
    with (output / new_name).open("wb") as destination:
        with gzip.GzipFile(fileobj=destination, mode="wb", mtime=0, filename="") as compressed:
            with tarfile.open(fileobj=compressed, mode="w") as patched:
                member = tarfile.TarInfo(new_name.removesuffix(".tar.gz"))
                member.size = len(library)
                member.mode = 0o755
                patched.addfile(member, io.BytesIO(library))
    print(f"Verified and repackaged {new_name}")
