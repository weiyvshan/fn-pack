#!/usr/bin/env python3
"""Exercise the raw release cache without making network requests."""
import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("magpie_prepare", Path(__file__).resolve().parents[1] / "scripts/prepare-binary.py")
PREPARE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PREPARE)


class Response(io.BytesIO):
    def geturl(self):
        return "https://example.invalid/magpie"


class ReleaseMetadataTests(unittest.TestCase):
    def test_pinned_release_and_package_version(self):
        project = Path(__file__).resolve().parents[1]
        lock = json.loads((project / "binary.lock.json").read_text(encoding="utf-8"))
        PREPARE.validate_lock(lock)
        self.assertEqual(lock["upstream_version"], "0.1.2091")
        self.assertEqual(lock["artifact"]["url"],
                         "https://github.com/yetone/magpie-releases/releases/download/v0.1.2091/magpie-cli-linux-amd64")
        self.assertEqual(lock["artifact"]["bytes"], 62312610)
        self.assertEqual(lock["artifact"]["sha256"],
                         "b01fd50bf4b618b5afa2eae757bb4d2ca7f85b6e35fc8789087dd49eaa3b0cf8")
        manifest = (project / "manifest").read_text(encoding="utf-8").splitlines()
        self.assertIn("version=0.1.2091", manifest)
        self.assertIn("## 0.1.2091", (project / "CHANGELOG.md").read_text(encoding="utf-8").splitlines())


class CacheTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.cache = Path(self.work.name)
        binary = bytearray(64)
        binary[:6] = b"\x7fELF\x02\x01"
        struct.pack_into("<H", binary, 18, 62)
        self.binary = bytes(binary)
        self.lock = {
            "schema_version": 1, "upstream_version": "0.1.1275",
            "artifact": {"name": "magpie-cli-linux-amd64", "url": "https://example.invalid/magpie",
                         "bytes": len(self.binary), "sha256": hashlib.sha256(self.binary).hexdigest(),
                         "elf_class": 64, "elf_data": "little-endian", "elf_machine": 62},
        }
        self.target = self.cache / "magpie/0.1.1275/magpie"

    def download(self, content=None, lock=None):
        with patch.object(PREPARE.urllib.request, "urlopen", return_value=Response(self.binary if content is None else content)):
            return PREPARE.prepare(self.lock if lock is None else lock, self.cache)

    def test_download_and_offline_reuse(self):
        self.assertEqual(self.download(), self.target)
        with patch.object(PREPARE.urllib.request, "urlopen", side_effect=AssertionError("network used")):
            self.assertEqual(PREPARE.prepare(self.lock, self.cache, True), self.target)
        self.assertEqual(self.target.stat().st_mode & 0o777, 0o755)

    def test_offline_missing(self):
        with self.assertRaises(ValueError):
            PREPARE.prepare(self.lock, self.cache, True)

    def test_corrupt_cache_offline(self):
        self.download()
        self.target.write_bytes(b"corrupt")
        with self.assertRaises(ValueError):
            PREPARE.prepare(self.lock, self.cache, True)

    def test_corrupt_cache_repaired(self):
        self.target.parent.mkdir(parents=True)
        self.target.write_bytes(b"corrupt")
        self.download()
        self.assertEqual(self.target.read_bytes(), self.binary)

    def test_failed_download_preserves_existing_file(self):
        self.download()
        bad_lock = copy.deepcopy(self.lock)
        bad_lock["artifact"]["sha256"] = "0" * 64
        with self.assertRaises(ValueError):
            self.download(lock=bad_lock)
        self.assertEqual(self.target.read_bytes(), self.binary)
        self.assertEqual(list(self.target.parent.glob("download-*")), [])

    def test_oversized_response(self):
        with self.assertRaises(ValueError):
            self.download(self.binary + b"extra")
        self.assertFalse(self.target.exists())

    def test_short_response(self):
        with self.assertRaises(ValueError):
            self.download(self.binary[:-1])
        self.assertFalse(self.target.exists())

    def test_wrong_elf_with_matching_hash(self):
        bad_binary = b"invalid" + self.binary[7:]
        lock = copy.deepcopy(self.lock)
        lock["artifact"]["sha256"] = hashlib.sha256(bad_binary).hexdigest()
        with self.assertRaises(ValueError):
            self.download(bad_binary, lock)

    def test_symlink_cache_rejected_offline(self):
        original = self.cache / "outside"
        original.write_bytes(self.binary)
        self.target.parent.mkdir(parents=True)
        self.target.symlink_to(original)
        with self.assertRaises(ValueError):
            PREPARE.prepare(self.lock, self.cache, True)
        self.assertEqual(original.read_bytes(), self.binary)

    def test_path_traversal_version(self):
        self.lock["upstream_version"] = "../0.1.1275"
        with self.assertRaises(ValueError):
            PREPARE.prepare(self.lock, self.cache)

    def test_online_replaces_symlink_not_its_target(self):
        outside = self.cache / "outside"
        outside.write_bytes(self.binary)
        self.target.parent.mkdir(parents=True)
        self.target.symlink_to(outside)
        self.download()
        self.assertFalse(self.target.is_symlink())
        self.assertEqual(self.target.read_bytes(), self.binary)
        self.assertEqual(outside.read_bytes(), self.binary)

    def test_redirect_to_http_rejected(self):
        with patch.object(Response, "geturl", return_value="http://example.invalid/magpie"):
            with self.assertRaises(ValueError):
                self.download()
        self.assertFalse(self.target.exists())

    def test_wrong_machine_with_matching_hash(self):
        binary = bytearray(self.binary)
        struct.pack_into("<H", binary, 18, 183)
        lock = copy.deepcopy(self.lock)
        lock["artifact"]["sha256"] = hashlib.sha256(binary).hexdigest()
        with self.assertRaises(ValueError):
            self.download(bytes(binary), lock)

    def test_wrong_byte_order_with_matching_hash(self):
        binary = bytearray(self.binary)
        binary[5] = 2
        lock = copy.deepcopy(self.lock)
        lock["artifact"]["sha256"] = hashlib.sha256(binary).hexdigest()
        with self.assertRaises(ValueError):
            self.download(bytes(binary), lock)

    def test_plain_http_rejected(self):
        self.lock["artifact"]["url"] = "http://example.invalid/magpie"
        with self.assertRaises(ValueError):
            PREPARE.prepare(self.lock, self.cache)


if __name__ == "__main__":
    unittest.main()
