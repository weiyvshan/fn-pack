#!/usr/bin/env python3
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('prepare', PROJECT / 'scripts/prepare-artifacts.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def ar(payload):
    header = ('data.tar/').ljust(16) + '0'.ljust(12) + '0'.ljust(6) + '0'.ljust(6) + '100644'.ljust(8) + str(len(payload)).ljust(10) + '`\n'
    return b'!<arch>\n' + header.encode() + payload + (b'\n' if len(payload) % 2 else b'')


class ArtifactsTest(unittest.TestCase):
    def test_digest_mismatch_rejected(self):
        with self.assertRaises(ValueError):
            m.verify(b'x', {'bytes': 1, 'sha256': '0' * 64})

    def test_size_mismatch_rejected(self):
        with self.assertRaises(ValueError):
            m.verify(b'x', {'bytes': 2, 'sha256': hashlib.sha256(b'x').hexdigest()})

    def test_ar_corruption_rejected(self):
        for blob in (b'', b'!<arch>\ninvalid', ar(b'x')[:-2]):
            with self.subTest(blob=blob), self.assertRaises(ValueError):
                m.data_archive(blob)

    def test_missing_members_rejected_before_output_created(self):
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode='w'):
            pass
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / 'app'
            with self.assertRaises(ValueError):
                m.unpack(ar(buf.getvalue()), output, {'binaries': {}})
            self.assertFalse(output.exists())

    def test_selected_symlink_rejected(self):
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode='w') as tar:
            item = tarfile.TarInfo('usr/bin/v2raya')
            item.type = tarfile.SYMTYPE
            item.linkname = '/etc/passwd'
            tar.addfile(item)
        with tempfile.TemporaryDirectory() as tmp, self.assertRaises(ValueError):
            m.unpack(ar(buf.getvalue()), Path(tmp) / 'app', {'binaries': {}})

    def test_lock_pins_matching_core_and_cpu(self):
        lock = json.loads((PROJECT / 'upstream.lock.json').read_text())
        self.assertEqual(lock['version'], '2.5.13')
        for name in ('v2raya', 'v2raya_core'):
            self.assertEqual(lock['binaries'][name]['goamd64'], 'v1')
            self.assertEqual(len(lock['binaries'][name]['sha256']), 64)

    def test_real_cached_package_has_complete_closure(self):
        lock = json.loads((PROJECT / 'upstream.lock.json').read_text())
        cache = m.CACHE / lock['archive']['filename']
        if not cache.exists():
            self.skipTest('no upstream archive cached')
        blob = cache.read_bytes()
        m.verify(blob, lock['archive'])
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / 'app'
            m.unpack(blob, output, lock)
            for relative, _ in m.MEMBERS.values():
                self.assertTrue((output / relative).is_file())
            self.assertEqual(len(list(output.rglob('*.*'))), 4)
            cpu_spec = importlib.util.spec_from_file_location('cpu', PROJECT / 'scripts/check-cpu-baseline.py')
            cpu = importlib.util.module_from_spec(cpu_spec)
            cpu_spec.loader.exec_module(cpu)
            for name in ('v2raya', 'v2raya_core'):
                binary = (output / 'bin' / name).read_bytes()
                cpu.verify(binary)
                self.assertIn(b'GOAMD64=v1', binary)
                with self.assertRaises(ValueError):
                    cpu.verify(binary.replace(b'GOAMD64=v1', b'GOAMD64=v3'))


if __name__ == '__main__':
    unittest.main()
