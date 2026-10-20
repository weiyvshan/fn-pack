#!/usr/bin/env python3
"""Compare SDK output with source or a prepared project and its binary lock."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import re
import struct
import tarfile

SOURCE = Path(__file__).resolve().parents[1]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def manifest(data):
    values = {}
    for line in data.decode().splitlines():
        if "=" in line and not line.lstrip().startswith(("#", ";")):
            key, value = line.split("=", 1)
            key = key.strip()
            assert key not in values, "duplicate manifest field: " + key
            values[key] = value.strip()
    return values


def files(archive):
    members = {}
    directories = set()
    seen = set()
    for member in archive.getmembers():
        path = Path(member.name)
        assert not path.is_absolute() and ".." not in path.parts, "unsafe archive path"
        assert member.isfile() or member.isdir(), "unexpected link or special file"
        name = path.as_posix()
        assert name not in seen, "duplicate archive member: " + name
        seen.add(name)
        expected = 0o755 if member.isdir() or name.startswith("cmd/") or name == "bin/magpie" else 0o644
        assert member.mode == expected, "incorrect mode: " + name
        if member.isfile():
            members[name] = archive.extractfile(member).read()
        else:
            directories.add(name)
    return members, directories


def check_directories(directories, filenames):
    expected = {"."}
    for filename in filenames:
        expected.update(parent.as_posix() for parent in Path(filename).parents)
    assert directories <= expected, "unexpected archive directories: " + repr(sorted(directories - expected))


def read_lock(path):
    lock = json.loads(path.read_text())
    assert lock.get("schema_version") == 1, "unsupported binary lock schema"
    assert isinstance(lock.get("upstream_version"), str) and lock["upstream_version"], "missing upstream version"
    artifact = lock["artifact"]
    assert artifact["name"] == "magpie-cli-linux-amd64", "unexpected binary artifact"
    assert type(artifact["bytes"]) is int and artifact["bytes"] > 0, "invalid locked binary size"
    assert re.fullmatch(r"[0-9a-f]{64}", artifact["sha256"]), "invalid locked SHA-256"
    assert artifact["elf_class"] == 64 and artifact["elf_data"] == "little-endian", "unsupported locked ELF format"
    assert artifact["elf_machine"] == 62, "unsupported locked ELF machine"
    return lock


def main():
    if not __debug__:
        raise SystemExit("Run this verifier without Python assertion optimization.")
    parser = argparse.ArgumentParser()
    parser.add_argument("fpk", type=Path)
    parser.add_argument("--project", type=Path, default=SOURCE)
    parser.add_argument("--lock", type=Path, default=SOURCE / "binary.lock.json")
    args = parser.parse_args()
    project = args.project.resolve()
    lock = read_lock(args.lock)
    artifact = lock["artifact"]
    raw = args.fpk.read_bytes()
    with tarfile.open(fileobj=io.BytesIO(raw)) as archive:
        outer, outer_directories = files(archive)
    expected_outer = {"app.tgz", "manifest", "LICENSE", "ICON.PNG", "ICON_256.PNG"}
    for folder in ("cmd", "config", "wizard"):
        expected_outer.update(str(path.relative_to(project)) for path in (project / folder).rglob("*") if path.is_file())
    assert set(outer) == expected_outer, "unexpected outer package contents"
    check_directories(outer_directories, expected_outer)
    compared = []
    for name, content in outer.items():
        if name not in ("manifest", "app.tgz"):
            assert content == (project / name).read_bytes(), "source mismatch: " + name
            compared.append(name)
    packaged_manifest = manifest(outer["manifest"])
    source_manifest = manifest((project / "manifest").read_bytes())
    checksum = packaged_manifest.pop("checksum", None)
    assert checksum and re.fullmatch(r"[0-9a-fA-F]{32}", checksum), "invalid or missing SDK checksum"
    app_tgz_md5 = hashlib.md5(outer["app.tgz"]).hexdigest()
    assert checksum.lower() == app_tgz_md5, "SDK checksum does not match app.tgz MD5"
    assert packaged_manifest == source_manifest, "manifest fields differ beyond SDK checksum"
    assert packaged_manifest["appname"] == "magpie", "unexpected package identity"
    assert re.fullmatch(r"[0-9]+(?:\.[0-9]+)+(?:-[0-9]+)?", source_manifest["version"]), "invalid package version"
    assert packaged_manifest["platform"] == "x86", "unexpected package platform"
    with tarfile.open(fileobj=io.BytesIO(outer["app.tgz"])) as archive:
        payload, payload_directories = files(archive)
    expected_payload = {str(path.relative_to(project / "app")) for path in (project / "app").rglob("*") if path.is_file()}
    expected_payload.add("bin/magpie")
    # fnpack 1.2.3 also copies resource declarations into the application payload.
    expected_payload.update(str(path.relative_to(project)) for path in (project / "config").rglob("*") if path.is_file())
    assert set(payload) == expected_payload, "unexpected application payload"
    check_directories(payload_directories, expected_payload)
    private_roots = {"run", "logs", "xdg", "etc", "var", "home", "data", "cache"}
    private_files = {"web.key", "web-url.txt", ".account-discovery-restored"}
    assert not any(Path(name).parts[0] in private_roots or Path(name).name in private_files for name in payload), "private runtime data included"
    source_binary_present = (project / "app/bin/magpie").is_file()
    for name, content in payload.items():
        source = project / name if name.startswith("config/") else project / "app" / name
        if name == "bin/magpie" and not source_binary_present:
            continue
        assert content == source.read_bytes(), "payload mismatch: " + name
        compared.append("app/" + name)
    binary = payload["bin/magpie"]
    assert len(binary) == artifact["bytes"], "official binary size mismatch"
    assert sha(binary) == artifact["sha256"], "official binary checksum mismatch"
    assert len(binary) >= 64 and binary[:6] == b"\x7fELF\x02\x01", "invalid ELF class or endianness"
    assert struct.unpack_from("<H", binary, 18)[0] == artifact["elf_machine"], "ELF machine mismatch"
    entry = json.loads(payload["ui/config"])[".url"]["magpie.main"]
    assert entry["port"] == "3430" and entry["url"] == "/", "unexpected management entry"
    print(json.dumps({
        "status": "passed", "version": source_manifest["version"],
        "upstream_version": lock["upstream_version"],
        "fpk": {"name": args.fpk.name, "bytes": len(raw), "sha256": sha(raw)},
        "app_tgz": {"bytes": len(outer["app.tgz"]), "sha256": sha(outer["app.tgz"]), "md5": app_tgz_md5},
        "binary": {"bytes": len(binary), "sha256": sha(binary), "elf_machine": artifact["elf_machine"]},
        "source_matches": sorted(compared), "source_match_count": len(compared),
        "source_binary_present": source_binary_present,
        "binary_matches_lock": True, "manifest_checksum_matches_app_tgz": True,
        "manifest_matches_except_sdk_checksum": True, "modes_checked": True,
        "private_runtime_data_excluded": True,
    }, indent=2))


if __name__ == "__main__":
    main()
