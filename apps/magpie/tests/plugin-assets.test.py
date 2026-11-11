#!/usr/bin/env python3
"""Offline asset validation, path safety and package contract regression."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

PROJECT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('plugins', PROJECT / 'scripts/prepare-plugins.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class Response(io.BytesIO):
    def geturl(self):
        return 'https://example.invalid/asset'


class Assets(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.cache = Path(self.temp.name)
        self.data = b'fixture data'
        self.item = {'filename': 'asset', 'url': 'https://example.invalid/asset',
                     'bytes': len(self.data), 'sha256': hashlib.sha256(self.data).hexdigest()}

    def test_download_verify_and_offline(self):
        with patch.object(MODULE.urllib.request, 'urlopen', return_value=Response(self.data)):
            path = MODULE.obtain(self.cache, self.item)
        with patch.object(MODULE.urllib.request, 'urlopen', side_effect=AssertionError('network')):
            self.assertEqual(MODULE.obtain(self.cache, self.item, True), path)

    def test_corrupt_cache_rejected(self):
        (self.cache / 'asset').write_bytes(b'bad')
        with self.assertRaises(ValueError):
            MODULE.obtain(self.cache, self.item, True)

    def test_checksum_failure_preserves_cache(self):
        (self.cache / 'asset').write_bytes(b'original')
        with patch.object(MODULE.urllib.request, 'urlopen', return_value=Response(b'x' * len(self.data))):
            with self.assertRaises(ValueError):
                MODULE.obtain(self.cache, self.item)
        self.assertEqual((self.cache / 'asset').read_bytes(), b'original')

    def test_size_limit(self):
        with patch.object(MODULE.urllib.request, 'urlopen', return_value=Response(self.data * 2)):
            with self.assertRaises(ValueError):
                MODULE.obtain(self.cache, self.item)

    def test_traversal(self):
        self.item['filename'] = '../asset'
        with self.assertRaises(ValueError):
            MODULE.obtain(self.cache, self.item)

    def test_symlink_cache_rejected(self):
        outside = self.cache / 'outside'
        outside.write_bytes(self.data)
        (self.cache / 'asset').symlink_to(outside)
        with self.assertRaises(ValueError):
            MODULE.obtain(self.cache, self.item, True)

    def test_staging_symlink_rejected(self):
        (self.cache / 'app').symlink_to(self.cache, target_is_directory=True)
        with self.assertRaises(ValueError):
            MODULE.stage_files(self.cache, {'bin/bun': self.data})

    def test_personal_data_not_distributed(self):
        self.assertEqual(MODULE.EMPTY_PERSONAS.splitlines()[-1], b'window.PERSONAS = [];')
        self.assertNotIn('page/personas.js', MODULE.PLUGIN_FILES)

    def test_pinned_contract(self):
        lock = json.loads((PROJECT / 'plugin.lock.json').read_text())
        self.assertEqual(lock['plugin']['commit'], '09ce906fc9aeee287c9d4891dd0b96bf2db12fb6')
        self.assertEqual(lock['plugin']['release'], 'v0.2.19')
        self.assertEqual(lock['bun']['version'], '1.4.2')
        self.assertEqual(lock['bun']['sha256'], 'c678040f14fe0440eb839d37cbd0ce4c051a32da72806ac97de6a6aab6bf728f')
        self.assertIn('version=0.1.3771', (PROJECT / 'manifest').read_text().splitlines())
        self.assertIn('## 0.1.3771', (PROJECT / 'CHANGELOG.md').read_text().splitlines())


if __name__ == '__main__':
    unittest.main()
