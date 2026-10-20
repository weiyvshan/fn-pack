#!/usr/bin/env python3
"""Exercise FPK container metadata with synthetic archives, without applications."""
import bz2
import gzip
import hashlib
import importlib.util
import io
import json
import lzma
import os
from pathlib import Path
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock
import zipfile
import zlib

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/normalize-fpk.py"
SPEC = importlib.util.spec_from_file_location("magpie_normalize_fpk", SCRIPT)
NORMALIZER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(NORMALIZER)
PAYLOAD = gzip.compress(b"synthetic inner application archive", mtime=0)
MANIFEST = ("appname=magpie\nversion=0.1.1275-3\nchecksum=%s\n" % hashlib.md5(PAYLOAD).hexdigest()).encode()


def make_tar(mode=0o600, pax=None, app_type=tarfile.REGTYPE, duplicate=None, name="app.tgz", missing=False):
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w", format=tarfile.PAX_FORMAT) as archive:
        if not missing:
            app = tarfile.TarInfo(name)
            app.mode = mode
            app.mtime = 1700000000
            app.pax_headers = pax or {}
            app.type = app_type
            app.linkname = "another-file" if app_type == tarfile.SYMTYPE else ""
            app.size = len(PAYLOAD) if app_type == tarfile.REGTYPE else 0
            archive.addfile(app, io.BytesIO(PAYLOAD) if app.size else None)
        if duplicate:
            app = tarfile.TarInfo(duplicate)
            app.size, app.mode = len(PAYLOAD), 0o644
            archive.addfile(app, io.BytesIO(PAYLOAD))
        for filename, data, permissions in (
            ("manifest", MANIFEST, 0o640),
            ("cmd/main", b"#!/bin/bash\nexit 0\n", 0o755),
            ("ICON.PNG", b"synthetic icon", 0o644),
        ):
            item = tarfile.TarInfo(filename)
            item.size, item.mode, item.uid, item.gid = len(data), permissions, 21, 22
            item.uname, item.gname, item.mtime = "fixture-user", "fixture-group", 1700000042
            archive.addfile(item, io.BytesIO(data))
    return buffer.getvalue()


def compressed(data, filename="sdk-original.fpk", mtime=1700000123, level=1):
    output = io.BytesIO()
    with gzip.GzipFile(fileobj=output, filename=filename, mode="wb", mtime=mtime, compresslevel=level) as archive:
        archive.write(data)
    return output.getvalue()


class MetadataTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="magpie-fpk-metadata-")
        self.root = Path(self.temporary.name)
        self.raw = self.root / "raw.fpk"
        self.named = self.root / "named.fpk"

    def tearDown(self):
        self.temporary.cleanup()

    def normalize(self, data):
        self.raw.write_bytes(data)
        before = self.raw.stat()
        result = NORMALIZER.normalize_fpk(self.raw, self.named)
        self.assertEqual(self.raw.read_bytes(), data)
        after = self.raw.stat()
        self.assertEqual((before.st_ino, before.st_mode, before.st_mtime_ns),
                         (after.st_ino, after.st_mode, after.st_mtime_ns))
        self.assertEqual(stat.S_IMODE(self.named.stat().st_mode), 0o644)
        return result, self.named.read_bytes()

    def assert_changed_fields_only(self, before, after):
        self.assertEqual(len(before), len(after))
        with tarfile.open(fileobj=io.BytesIO(before), mode="r:") as archive:
            member = archive.getmember("app.tgz")
            offset = member.offset_data - tarfile.BLOCKSIZE
            names = archive.getnames()
            original_data = {m.name: archive.extractfile(m).read() for m in archive.getmembers() if m.isfile()}
        changed = {i for i, (left, right) in enumerate(zip(before, after)) if left != right}
        allowed = set(range(offset + 100, offset + 108)) | set(range(offset + 148, offset + 156))
        self.assertTrue(changed)
        self.assertTrue(changed <= allowed, changed - allowed)
        with tarfile.open(fileobj=io.BytesIO(after), mode="r:") as archive:
            self.assertEqual(archive.getnames(), names)
            app = archive.getmember("app.tgz")
            self.assertEqual(app.mode, 0o644)
            self.assertEqual({m.name: archive.extractfile(m).read() for m in archive.getmembers() if m.isfile()}, original_data)
            self.assertEqual(archive.extractfile("app.tgz").read(), PAYLOAD)
            self.assertEqual(archive.extractfile("manifest").read(), MANIFEST)
        header = tarfile.TarInfo.frombuf(after[offset:offset + 512], "utf-8", "strict")
        self.assertEqual(header.mode, 0o644)

    def reject(self, data):
        self.raw.write_bytes(data)
        with self.assertRaises((ValueError, OSError, EOFError, tarfile.TarError, zlib.error)):
            NORMALIZER.normalize_fpk(self.raw, self.named)
        self.assertEqual(self.raw.read_bytes(), data)
        self.assertFalse(os.path.lexists(self.named))

    def test_plain_0600(self):
        raw = make_tar(0o600)
        result, output = self.normalize(raw)
        self.assertEqual(result["format"], "tar")
        self.assertTrue(result["changed"])
        self.assert_changed_fields_only(raw, output)

    def test_plain_0700(self):
        raw = make_tar(0o700)
        _, output = self.normalize(raw)
        self.assert_changed_fields_only(raw, output)

    def test_plain_0644_is_byte_identical(self):
        raw = make_tar(0o644)
        result, output = self.normalize(raw)
        self.assertFalse(result["changed"])
        self.assertEqual(output, raw)

    def test_gzip_0600(self):
        decoded = make_tar(0o600)
        result, output = self.normalize(compressed(decoded))
        self.assertEqual(result["format"], "gzip")
        self.assert_changed_fields_only(decoded, gzip.decompress(output))
        self.assertEqual(output[4:8], b"\0" * 4)
        self.assertEqual(output[3] & 8, 0)
        self.assertEqual(output[8], 0)

    def test_gzip_0700(self):
        decoded = make_tar(0o700)
        _, output = self.normalize(compressed(decoded))
        self.assert_changed_fields_only(decoded, gzip.decompress(output))

    def test_gzip_0644_preserves_original_compressed_bytes(self):
        raw = compressed(make_tar(0o644), filename="preserve-this-header", mtime=123456, level=9)
        result, output = self.normalize(raw)
        self.assertFalse(result["changed"])
        self.assertEqual(output, raw)

    def test_pax_timestamp_precedes_real_header(self):
        for mode in (0o600, 0o700):
            for is_gzip in (False, True):
                with self.subTest(mode=oct(mode), gzip=is_gzip):
                    before = make_tar(mode, pax={"mtime": "1700000000.123456789"})
                    named = self.root / ("pax-%o-%s.fpk" % (mode, is_gzip))
                    self.raw.write_bytes(compressed(before) if is_gzip else before)
                    result = NORMALIZER.normalize_fpk(self.raw, named)
                    self.assertGreater(result["header_offset"], 0)
                    after = gzip.decompress(named.read_bytes()) if is_gzip else named.read_bytes()
                    self.assert_changed_fields_only(before, after)
                    with tarfile.open(fileobj=io.BytesIO(after), mode="r:") as archive:
                        self.assertEqual(archive.getmember("app.tgz").pax_headers, {"mtime": "1700000000.123456789"})

    def test_gzip_normalization_is_deterministic(self):
        self.raw.write_bytes(compressed(make_tar()))
        second = self.root / "second.fpk"
        NORMALIZER.normalize_fpk(self.raw, self.named)
        NORMALIZER.normalize_fpk(self.raw, second)
        self.assertEqual(self.named.read_bytes(), second.read_bytes())

    def test_success_output_is_0644_under_restrictive_umask(self):
        old = os.umask(0o077)
        try:
            self.normalize(compressed(make_tar()))
        finally:
            os.umask(old)

    def test_duplicate_and_alias_app_members(self):
        for name in ("app.tgz", "./app.tgz"):
            with self.subTest(name=name):
                self.reject(make_tar(duplicate=name))

    def test_missing_and_nonregular_app_member(self):
        self.reject(make_tar(missing=True))
        for kind in (tarfile.SYMTYPE, tarfile.LNKTYPE, tarfile.DIRTYPE):
            with self.subTest(kind=kind):
                self.reject(make_tar(app_type=kind))

    def test_reject_pax_mode_and_ambiguous_overrides(self):
        for key, value in (("mode", "0600"), ("SCHILY.mode", "0600"), ("path", "app.tgz"), ("size", "1")):
            with self.subTest(key=key):
                self.reject(make_tar(pax={key: value}))

    def test_corrupt_first_and_later_header(self):
        original = make_tar()
        for name in ("app.tgz", "manifest"):
            with tarfile.open(fileobj=io.BytesIO(original), mode="r:") as archive:
                offset = archive.getmember(name).offset_data - 512
            changed = bytearray(original)
            changed[offset] ^= 1
            with self.subTest(name=name):
                self.reject(bytes(changed))

    def test_unsafe_and_ambiguous_paths(self):
        for name in ("../app.tgz", "/app.tgz", "nested/../app.tgz", "app.tgz/child"):
            with self.subTest(name=name):
                self.reject(make_tar(duplicate=name))

    def test_truncated_tar(self):
        original = make_tar()
        self.reject(original[:-1])
        self.reject(original[:512])

    def test_gzip_crc_and_truncation(self):
        original = compressed(make_tar())
        changed = bytearray(original)
        changed[-8] ^= 1
        self.reject(bytes(changed))
        self.reject(original[:-6])

    def test_other_compression_is_rejected(self):
        raw = make_tar()
        zipped = io.BytesIO()
        with zipfile.ZipFile(zipped, mode="w") as archive:
            archive.writestr("archive.tar", raw)
        for payload in (bz2.compress(raw), lzma.compress(raw), zlib.compress(raw), zipped.getvalue()):
            with self.subTest(magic=payload[:4]):
                self.reject(payload)

    def test_concatenated_tar_is_rejected(self):
        self.reject(make_tar() + make_tar())

    def test_existing_regular_target_is_untouched(self):
        self.raw.write_bytes(make_tar())
        self.named.write_bytes(b"existing target")
        before = self.named.stat()
        with self.assertRaises(FileExistsError):
            NORMALIZER.normalize_fpk(self.raw, self.named)
        self.assertEqual(self.named.read_bytes(), b"existing target")
        self.assertEqual(self.named.stat().st_ino, before.st_ino)

    def test_existing_directory_target_is_untouched(self):
        self.raw.write_bytes(make_tar())
        self.named.mkdir()
        (self.named / "sentinel").write_bytes(b"keep")
        with self.assertRaises(OSError):
            NORMALIZER.normalize_fpk(self.raw, self.named)
        self.assertEqual((self.named / "sentinel").read_bytes(), b"keep")

    def test_existing_symlink_target_is_untouched(self):
        self.raw.write_bytes(make_tar())
        target = self.root / "elsewhere"
        target.write_bytes(b"keep target")
        self.named.symlink_to(target)
        with self.assertRaises(FileExistsError):
            NORMALIZER.normalize_fpk(self.raw, self.named)
        self.assertTrue(self.named.is_symlink())
        self.assertEqual(target.read_bytes(), b"keep target")

    def test_dangling_symlink_target_is_untouched(self):
        self.raw.write_bytes(make_tar())
        target = self.root / "absent"
        self.named.symlink_to(target)
        with self.assertRaises(FileExistsError):
            NORMALIZER.normalize_fpk(self.raw, self.named)
        self.assertTrue(self.named.is_symlink())
        self.assertFalse(target.exists())

    def test_same_source_and_target_is_rejected(self):
        raw = make_tar()
        self.raw.write_bytes(raw)
        with self.assertRaises(FileExistsError):
            NORMALIZER.normalize_fpk(self.raw, self.raw)
        self.assertEqual(self.raw.read_bytes(), raw)

    def test_failed_copy_removes_only_new_output(self):
        raw = make_tar()
        self.raw.write_bytes(raw)
        def failure(source, output, length):
            output.write(b"partial output")
            raise OSError("synthetic copy failure")
        with mock.patch.object(NORMALIZER.shutil, "copyfileobj", side_effect=failure):
            with self.assertRaises(OSError):
                NORMALIZER.normalize_fpk(self.raw, self.named)
        self.assertFalse(os.path.lexists(self.named))
        self.assertEqual(self.raw.read_bytes(), raw)

    def test_cli_reports_normalization(self):
        self.raw.write_bytes(compressed(make_tar()))
        result = subprocess.run([sys.executable, "-I", "-B", str(SCRIPT), str(self.raw), str(self.named)],
                                capture_output=True, text=True, check=True)
        report = json.loads(result.stdout)
        self.assertEqual(report["format"], "gzip")
        self.assertEqual(report["normalized_mode"], "0644")
        self.assertTrue(report["changed"])


if __name__ == "__main__":
    unittest.main()
