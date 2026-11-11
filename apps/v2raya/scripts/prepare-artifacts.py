#!/usr/bin/env python3
"""Verify a pinned Debian archive and extract selected files, never install it.

--verify-only checks cache without writing. --output requires a fresh staging
app directory. No archive member paths, links or package maintainer scripts run.
"""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import tarfile
import tempfile
import urllib.request

PROJECT = Path(__file__).resolve().parents[1]
CACHE = PROJECT.parents[1] / '.tmp/v2raya-artifacts'
MEMBERS = {
    'usr/bin/v2raya': ('bin/v2raya', 0o755),
    'usr/bin/v2raya_core': ('bin/v2raya_core', 0o755),
    'usr/share/v2raya/geoip.dat': ('share/geoip.dat', 0o644),
    'usr/share/v2raya/geosite.dat': ('share/geosite.dat', 0o644),
    'usr/share/icons/hicolor/64x64/apps/v2raya.png': ('ui/images/icon_64.png', 0o644),
    'usr/share/icons/hicolor/256x256/apps/v2raya.png': ('ui/images/icon_256.png', 0o644),
}


def verify(data, spec):
    if len(data) != spec['bytes'] or hashlib.sha256(data).hexdigest() != spec['sha256']:
        raise ValueError('artifact size or SHA-256 mismatch')


def data_archive(blob):
    if not blob.startswith(b'!<arch>\n'):
        raise ValueError('not a Debian ar archive')
    offset = 8
    found = []
    while offset < len(blob):
        header = blob[offset:offset + 60]
        if len(header) != 60 or header[58:] != b'`\n':
            raise ValueError('invalid ar header')
        name = header[:16].decode('ascii').strip().rstrip('/')
        size = int(header[48:58])
        offset += 60
        if size < 0 or offset + size > len(blob):
            raise ValueError('invalid ar size')
        if name in ('data.tar.xz', 'data.tar.gz', 'data.tar'):
            found.append(blob[offset:offset + size])
        offset += size + (size % 2)
    if len(found) != 1:
        raise ValueError('expected exactly one supported data archive')
    return found[0]


def unpack(blob, output, lock):
    output = Path(output)
    if output.exists():
        raise ValueError('output must be a fresh staging directory')
    selected = {}
    with tarfile.open(fileobj=io.BytesIO(data_archive(blob)), mode='r:*') as archive:
        for member in archive:
            name = member.name.removeprefix('./')
            if name not in MEMBERS:
                continue
            if name in selected or not member.isfile() or member.size > 100 * 1024 * 1024:
                raise ValueError('invalid selected archive member')
            content = archive.extractfile(member).read()
            if name.startswith('usr/bin/'):
                verify(content, lock['binaries'][name.rsplit('/', 1)[1]])
            selected[name] = content
    if set(selected) != set(MEMBERS):
        raise ValueError('required package assets missing')
    output.mkdir(parents=True)
    for name, content in selected.items():
        relative, mode = MEMBERS[name]
        target = output / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)
        target.chmod(mode)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--offline', action='store_true')
    parser.add_argument('--verify-only', action='store_true')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.verify_only and args.output:
        parser.error('--verify-only cannot extract')
    lock = json.loads((PROJECT / 'upstream.lock.json').read_text(encoding='utf-8'))
    spec = lock['archive']
    cached = CACHE / spec['filename']
    if not cached.is_file():
        if args.offline or args.verify_only:
            raise ValueError('pinned Debian archive not cached')
        CACHE.mkdir(parents=True, exist_ok=True)
        fd, name = tempfile.mkstemp(prefix='download-', dir=CACHE)
        temporary = Path(name)
        try:
            with os.fdopen(fd, 'wb') as out, urllib.request.urlopen(spec['url'], timeout=120) as response:
                shutil.copyfileobj(response, out)
            verify(temporary.read_bytes(), spec)
            os.replace(temporary, cached)
        finally:
            temporary.unlink(missing_ok=True)
    blob = cached.read_bytes()
    verify(blob, spec)
    if args.output:
        unpack(blob, args.output, lock)
    print('v2rayA 2.5.13 archive verified; no package installation performed')


if __name__ == '__main__':
    main()
