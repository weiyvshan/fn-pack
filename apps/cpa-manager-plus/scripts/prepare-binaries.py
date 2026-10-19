#!/usr/bin/env python3
"""Prepare hash-pinned release binaries in an ignored, atomically updated cache."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import tarfile
import tempfile
import urllib.request


def matches(path, size, digest):
    if path.is_symlink() or not path.is_file() or path.stat().st_size != size:
        return False
    checksum = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            checksum.update(chunk)
    return checksum.hexdigest() == digest


def prepare(component, cache, offline=False):
    name, version = component["name"], component["version"]
    if any(part in ("", ".", "..") or "/" in part or "\\" in part
           for part in (name, version)):
        raise ValueError("Invalid component cache path")
    target = cache / name / version / name
    if matches(target, component["bytes"], component["sha256"]):
        target.chmod(0o755)
        return target
    if offline:
        raise ValueError(f"Missing or invalid cached binary: {target}")

    archive = component["archive"]
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="download-", dir=target.parent) as work:
        work = Path(work)
        download = work / "release.tar.gz"
        request = urllib.request.Request(archive["url"], headers={"User-Agent": "fn-pack"})
        print(f"Downloading {name} {version}", flush=True)
        with urllib.request.urlopen(request, timeout=60) as response, download.open("wb") as output:
            received = 0
            while chunk := response.read(1024 * 1024):
                received += len(chunk)
                if received > archive["bytes"]:
                    raise ValueError(f"Archive exceeds locked size: {name}")
                output.write(chunk)
        if not matches(download, archive["bytes"], archive["sha256"]):
            raise ValueError(f"Archive size or SHA-256 mismatch: {name}")

        binary = work / "binary"
        with tarfile.open(download, "r:gz") as package:
            member = package.getmember(archive["member"])
            if not member.isfile() or member.size != component["bytes"]:
                raise ValueError(f"Invalid locked archive member: {name}")
            with package.extractfile(member) as source, binary.open("wb") as output:
                shutil.copyfileobj(source, output, 1024 * 1024)
        if not matches(binary, component["bytes"], component["sha256"]):
            raise ValueError(f"Binary size or SHA-256 mismatch: {name}")
        binary.chmod(0o755)
        os.replace(binary, target)
    return target


def main():
    project = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache-dir", type=Path,
                        default=project.parents[1] / ".tmp" / "cpa-manager-plus-binaries")
    parser.add_argument("--offline", action="store_true",
                        help="Validate existing cache without downloading")
    args = parser.parse_args()
    lock = json.loads((project / "binary.lock.json").read_text(encoding="utf-8"))
    if lock.get("schema_version") != 1 or not lock.get("components"):
        parser.error("Unsupported or empty binary.lock.json")
    try:
        for component in lock["components"]:
            path = prepare(component, args.cache_dir.resolve(), args.offline)
            print(f"Verified={path}", flush=True)
    except (OSError, ValueError, KeyError, tarfile.TarError) as error:
        raise SystemExit(f"prepare-binaries: {error}") from error


if __name__ == "__main__":
    main()
