#!/usr/bin/env python3
"""Prepare digest-pinned, offline-capable plugin and Bun payloads."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
import tarfile
import tempfile
import urllib.request
import zipfile

PROJECT = Path(__file__).resolve().parents[1]
PLUGIN_FILES = ('package.json', 'hooks.js', 'page/index.html', 'page/app.js', 'page/style.css', 'README.md')
EMPTY_PERSONAS = b'// No build-machine personal data is distributed. Import personas in the plugin page.\nwindow.PERSONAS = [];\n'


def matches(path, item):
    return (not path.is_symlink() and path.is_file() and path.stat().st_size == item['bytes']
            and hashlib.sha256(path.read_bytes()).hexdigest() == item['sha256'])


def obtain(cache, item, offline=False):
    name = item['filename']
    if Path(name).name != name or not item['url'].startswith('https://'):
        raise ValueError('Invalid asset name or URL')
    target = cache / name
    if matches(target, item):
        return target
    if offline:
        raise ValueError('Missing or invalid cached asset: ' + str(target))
    cache.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='download-', dir=cache) as work:
        download = Path(work) / name
        request = urllib.request.Request(item['url'], headers={'User-Agent': 'fn-pack'})
        with urllib.request.urlopen(request, timeout=60) as source, download.open('wb') as output:
            if not source.geturl().startswith('https://'):
                raise ValueError('Non-HTTPS redirect')
            received = 0
            while chunk := source.read(1024 * 1024):
                received += len(chunk)
                if received > item['bytes']:
                    raise ValueError('Asset exceeds locked size')
                output.write(chunk)
        if not matches(download, item):
            raise ValueError('Asset size or SHA-256 mismatch')
        os.replace(download, target)
    return target


def payload(lock, paths):
    result = {}
    prefix = 'agent-purge-' + lock['plugin']['commit'] + '/'
    with tarfile.open(paths['plugin'], 'r:gz') as archive:
        members = archive.getmembers()
        names = [m.name for m in members]
        if len(names) != len(set(names)):
            raise ValueError('Duplicate source members')
        for name in PLUGIN_FILES + ('LICENSE',):
            source = prefix + ('LICENSE' if name == 'LICENSE' else 'magpie-plugin/' + name)
            member = archive.getmember(source)
            if not member.isfile() or member.size > 1024 * 1024:
                raise ValueError('Unsafe plugin member: ' + source)
            data = archive.extractfile(member).read()
            destination = 'licenses/agent-purge-LICENSE' if name == 'LICENSE' else 'plugins/magpie-plugin/' + name
            result[destination] = data
    metadata = json.loads(result['plugins/magpie-plugin/package.json'])
    if metadata['version'] != lock['plugin']['package_version'] or metadata.get('dependencies'):
        raise ValueError('Unexpected plugin version or dependency closure')
    if metadata['magpie']['hooks'] != './hooks.js':
        raise ValueError('Unexpected hook entry')
    result['plugins/magpie-plugin/page/personas.js'] = EMPTY_PERSONAS
    with zipfile.ZipFile(paths['bun']) as archive:
        member = archive.getinfo(lock['bun']['member'])
        if len(archive.namelist()) != len(set(archive.namelist())) or member.file_size > 200 * 1024 * 1024:
            raise ValueError('Invalid Bun archive')
        binary = archive.read(member)
    if binary[:6] != b'\x7fELF\x02\x01' or struct.unpack_from('<H', binary, 18)[0] != 62:
        raise ValueError('Bun must be ELF64 little-endian x86-64')
    result['bin/bun'] = binary
    result['licenses/bun-LICENSE.md'] = paths['bun_license'].read_bytes()
    return result


def prepare(cache, lock, offline=False):
    if lock['schema_version'] != 1:
        raise ValueError('Unknown plugin lock schema')
    paths = {name: obtain(cache, lock[name], offline) for name in ('plugin', 'bun', 'bun_license')}
    return payload(lock, paths)


def stage_files(stage, files):
    for name, data in files.items():
        path = stage / 'app' / name
        if path.is_symlink() or any(p.is_symlink() for p in path.parents):
            raise ValueError('Symlink in staging path')
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        path.chmod(0o755 if name == 'bin/bun' else 0o644)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache-dir', type=Path, default=PROJECT.parents[1] / '.tmp/magpie-plugins')
    parser.add_argument('--offline', action='store_true')
    parser.add_argument('--stage', type=Path)
    args = parser.parse_args()
    lock = json.loads((PROJECT / 'plugin.lock.json').read_text())
    files = prepare(args.cache_dir, lock, args.offline)
    if args.stage:
        stage_files(args.stage, files)
    print('Verified plugin=' + lock['plugin']['commit'] + ' Bun=' + lock['bun']['version'])


if __name__ == '__main__':
    main()
