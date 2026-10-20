#!/usr/bin/env python3
"""Download the pinned Magpie CLI into an atomically updated build cache."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import tempfile
import urllib.parse
import urllib.request


def validate_lock(lock):
    if lock.get("schema_version") != 1:
        raise ValueError("Unsupported binary lock schema")
    version = lock.get("upstream_version", "")
    if not isinstance(version, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+)+", version):
        raise ValueError("Invalid upstream version")
    artifact = lock["artifact"]
    if artifact["name"] != "magpie-cli-linux-amd64":
        raise ValueError("The lock must select the headless Linux amd64 CLI")
    url = urllib.parse.urlsplit(artifact["url"])
    if url.scheme != "https" or not url.netloc or url.username or url.password:
        raise ValueError("The release URL must use HTTPS without credentials")
    if type(artifact["bytes"]) is not int or artifact["bytes"] < 20:
        raise ValueError("Invalid locked binary size")
    if not re.fullmatch(r"[0-9a-f]{64}", artifact["sha256"]):
        raise ValueError("Invalid locked SHA-256")
    if (artifact["elf_class"], artifact["elf_data"], artifact["elf_machine"]) != (64, "little-endian", 62):
        raise ValueError("The package requires an ELF64 little-endian x86-64 binary")


def matches(path, artifact):
    if path.is_symlink() or not path.is_file() or path.stat().st_size != artifact["bytes"]:
        return False
    digest = hashlib.sha256()
    with path.open("rb") as source:
        header = source.read(20)
        if header[:6] != b"\x7fELF\x02\x01" or len(header) < 20:
            return False
        if struct.unpack_from("<H", header, 18)[0] != artifact["elf_machine"]:
            return False
        digest.update(header)
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest() == artifact["sha256"]


def prepare(lock, cache, offline=False):
    validate_lock(lock)
    artifact = lock["artifact"]
    target = cache / "magpie" / lock["upstream_version"] / "magpie"
    if matches(target, artifact):
        target.chmod(0o755)
        return target
    if offline:
        raise ValueError(f"Missing or invalid cached binary: {target}")
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="download-", dir=target.parent) as directory:
        download = Path(directory) / "magpie"
        request = urllib.request.Request(artifact["url"], headers={"User-Agent": "fn-pack"})
        print(f"Downloading Magpie {lock['upstream_version']}", flush=True)
        with urllib.request.urlopen(request, timeout=60) as response, download.open("wb") as output:
            if urllib.parse.urlsplit(response.geturl()).scheme != "https":
                raise ValueError("The download was redirected away from HTTPS")
            received = 0
            for chunk in iter(lambda: response.read(1024 * 1024), b""):
                received += len(chunk)
                if received > artifact["bytes"]:
                    raise ValueError("Release binary exceeds its locked size")
                output.write(chunk)
        if not matches(download, artifact):
            raise ValueError(f"Release binary validation failed ({received}/{artifact['bytes']} bytes): "
                             "size, SHA-256 or ELF header mismatch")
        download.chmod(0o755)
        os.replace(download, target)
    return target


def main():
    project = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache-dir", type=Path, default=project.parents[1] / ".tmp/magpie-binaries")
    parser.add_argument("--offline", action="store_true", help="Verify an existing cache without network access")
    args = parser.parse_args()
    try:
        lock = json.loads((project / "binary.lock.json").read_text(encoding="utf-8"))
        path = prepare(lock, args.cache_dir.resolve(), args.offline)
        print(f"Verified={path}", flush=True)
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise SystemExit(f"prepare-binary: {error}") from error


if __name__ == "__main__":
    main()
