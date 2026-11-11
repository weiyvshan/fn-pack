#!/usr/bin/env python3
"""Fail on incomplete packaging contracts; no runtime mutation or downloads."""
import ast
import hashlib
import json
from pathlib import Path
import re
import struct

p = Path(__file__).resolve().parents[1]
fields = dict(line.split('=', 1) for line in (p / 'manifest').read_text().splitlines() if '=' in line)
assert fields['appname'] == p.name == 'v2raya'
assert fields['platform'] == 'x86'
assert fields['install_dep_apps'] == 'python312'
assert fields['service_port'] == '2017'
assert '## ' + fields['version'] in (p / 'CHANGELOG.md').read_text().splitlines()
entry = json.loads((p / 'app/ui/config').read_text())['.url'][fields['desktop_applaunchname']]
assert entry['port'] == fields['service_port'] and entry['url'] == '/'
privilege = json.loads((p / 'config/privilege').read_text())
assert privilege['defaults']['run-as'] == 'package'
assert privilege['username'] == privilege['groupname'] == 'v2raya'
json.loads((p / 'config/resource').read_text())
for name in ('main','install_init','install_callback','upgrade_init','upgrade_callback',
             'uninstall_init','uninstall_callback','config_init','config_callback'):
    text = (p / 'cmd' / name).read_text()
    assert text.startswith('#!/bin/sh\n'), name
    assert b'\r' not in (p / 'cmd' / name).read_bytes(), name
    if name != 'main':
        assert name in text, name
for path in p.rglob('*.py'):
    ast.parse(path.read_text(encoding='utf-8'))
for path in (p / 'wizard').iterdir():
    document = json.loads(path.read_text())
    for step in document:
        for item in step['items']:
            if 'initValue' in item:
                assert isinstance(item['initValue'], str)
for filename, size in [('ICON.PNG',64), ('ICON_256.PNG',256)]:
    data = (p / filename).read_bytes()
    assert data[:8] == b'\x89PNG\r\n\x1a\n'
    assert struct.unpack('>II', data[16:24]) == (size,size)
lock = json.loads((p / 'upstream.lock.json').read_text())
assert len(lock['archive']['sha256']) == 64 and lock['archive']['bytes'] > 0
for name in ('v2raya', 'v2raya_core'):
    assert lock['binaries'][name]['goamd64'] == 'v1'
assert (p / 'app/licenses/v2rayA-AGPL-3.0.txt').is_file()
assert (p / 'THIRD_PARTY_NOTICES.md').is_file()
for directory in ('app','cmd','config'):
    for path in (p / directory).rglob('*'):
        if path.is_file() and path.suffix not in ('.png','.PNG'):
            text = path.read_text(encoding='utf-8')
            assert '\r' not in text, str(path)
            assert not re.search(r'gh-proxy|ghproxy|npmmirror', text), str(path)
print('v2rayA source contracts passed')
