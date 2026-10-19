#!/usr/bin/env python3
"""Offline regression tests for the pinned binary cache."""
import copy
import hashlib
import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "prepare_binaries", Path(__file__).resolve().parents[1] / "scripts/prepare-binaries.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class BinaryCacheTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.cache = Path(self.work.name)
        self.payload = b"fixture binary"
        self.archive = self.make_archive()
        self.component = {
            "name": "fixture", "version": "1.0", "bytes": len(self.payload),
            "sha256": hashlib.sha256(self.payload).hexdigest(),
            "archive": {"url": "https://example.invalid/release.tar.gz", "member": "binary",
                        "bytes": len(self.archive),
                        "sha256": hashlib.sha256(self.archive).hexdigest()},
        }
        self.target = self.cache / "fixture/1.0/fixture"

    def make_archive(self, symlink=False):
        result = io.BytesIO()
        with tarfile.open(fileobj=result, mode="w:gz") as archive:
            member = tarfile.TarInfo("binary")
            if symlink:
                member.type, member.linkname = tarfile.SYMTYPE, "/outside"
                archive.addfile(member)
            else:
                member.size = len(self.payload)
                archive.addfile(member, io.BytesIO(self.payload))
        return result.getvalue()

    def prepare(self, component=None, payload=None):
        with patch("urllib.request.urlopen", return_value=io.BytesIO(
                self.archive if payload is None else payload)):
            return module.prepare(component or self.component, self.cache)

    def test_valid_download_and_offline_reuse(self):
        target = self.prepare()
        self.assertEqual(target.read_bytes(), self.payload)
        self.assertEqual(target.stat().st_mode & 0o777, 0o755)
        with patch("urllib.request.urlopen", side_effect=AssertionError("network used")):
            self.assertEqual(module.prepare(self.component, self.cache, True), target)

    def test_missing_cache_fails_offline(self):
        with self.assertRaises(ValueError):
            module.prepare(self.component, self.cache, True)

    def test_corrupt_cache_fails_offline(self):
        self.target.parent.mkdir(parents=True)
        self.target.write_bytes(b"bad")
        with self.assertRaises(ValueError):
            module.prepare(self.component, self.cache, True)

    def test_bad_archive_never_replaces_cache(self):
        self.target.parent.mkdir(parents=True)
        self.target.write_bytes(b"old")
        with self.assertRaises(ValueError):
            self.prepare(payload=b"corrupted download")
        self.assertEqual(self.target.read_bytes(), b"old")
        self.assertEqual(list(self.target.parent.glob("download-*")), [])

    def test_wrong_binary_digest_fails(self):
        component = copy.deepcopy(self.component)
        component["sha256"] = "0" * 64
        with self.assertRaises(ValueError):
            self.prepare(component)
        self.assertFalse(self.target.exists())

    def test_symlink_member_is_rejected(self):
        archive = self.make_archive(symlink=True)
        component = copy.deepcopy(self.component)
        component["archive"].update(bytes=len(archive), sha256=hashlib.sha256(archive).hexdigest())
        with self.assertRaises(ValueError):
            self.prepare(component, archive)
        self.assertFalse(self.target.exists())

    def test_invalid_cache_path_is_rejected(self):
        component = copy.deepcopy(self.component)
        component["name"] = "../outside"
        with self.assertRaises(ValueError):
            self.prepare(component)


if __name__ == "__main__":
    unittest.main()
