#!/usr/bin/env python3
"""Assemble in a unique disposable tree, audit, pack and compare actual bytes."""
import hashlib
import io
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile


def run(args, **kwargs):
    subprocess.run([str(x) for x in args], check=True, **kwargs)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    project, root, skill = map(lambda x: Path(x).resolve(), sys.argv[1:])
    fields = dict(line.split('=', 1) for line in (project / 'manifest').read_text().splitlines() if '=' in line)
    assert fields['appname'] == 'v2raya' and fields['platform'] == 'x86'
    version = fields['version']
    assert '## ' + version in (project / 'CHANGELOG.md').read_text().splitlines()
    build = root / 'build'
    build.mkdir(exist_ok=True)
    final = build / f'v2raya_{version}_x86.fpk'
    if final.exists():
        raise RuntimeError('refusing to overwrite existing FPK: ' + str(final))
    fnpack = skill / 'bin/fnpack-1.2.3-linux-amd64'
    assert digest(fnpack) == (Path(str(fnpack) + '.sha256').read_text().split()[0])
    run(['sh', project / 'scripts/test-package.sh'])
    with tempfile.TemporaryDirectory(prefix='v2raya-build-') as temporary:
        work = Path(temporary)
        stage = work / 'stage'
        stage.mkdir()
        # Fresh app tree is populated only from verified assets, then local source.
        run([sys.executable, '-B', project / 'scripts/prepare-artifacts.py', '--output', stage / 'app'])
        shutil.copytree(project / 'app', stage / 'app', dirs_exist_ok=True)
        for name in ('manifest', 'ICON.PNG', 'ICON_256.PNG'):
            shutil.copyfile(project / name, stage / name)
        for name in ('cmd', 'config', 'wizard'):
            shutil.copytree(project / name, stage / name)
        # fnpack injects these into app.tgz as well; stage exact copies so the
        # payload manifest and byte verification include the SDK-generated pair.
        shutil.copytree(project / 'config', stage / 'app/config')
        shutil.copyfile(project / 'THIRD_PARTY_NOTICES.md', stage / 'app/THIRD_PARTY_NOTICES.md')
        shutil.copytree(project / 'assets', stage / 'app/assets')
        for path in stage.rglob('*'):
            if path.is_dir():
                path.chmod(0o755)
            else:
                path.chmod(0o755 if path.parent == stage / 'cmd' or path in
                           (stage / 'app/bin/v2raya', stage / 'app/bin/v2raya_core') else 0o644)
        for name in ('v2raya', 'v2raya_core'):
            run([sys.executable, '-B', project / 'scripts/check-cpu-baseline.py', stage / 'app/bin' / name])
        run(['bash', skill / 'scripts/audit_fnos_project.sh', '--project-path', stage, '--format', 'json'])
        run([fnpack, 'build', '--directory', stage], cwd=work)
        produced = work / 'v2raya.fpk'
        if not produced.is_file():
            raise RuntimeError('fnpack returned without an output')
        with tarfile.open(produced) as outer:
            raw_manifest = outer.extractfile('manifest').read().decode()
            actual = dict((k.strip(), v.strip()) for k, v in
                          (line.split('=', 1) for line in raw_manifest.splitlines() if '=' in line))
            assert actual['version'] == version and actual['appname'] == 'v2raya'
            for directory in ('cmd', 'config', 'wizard'):
                for path in (stage / directory).rglob('*'):
                    if path.is_file():
                        assert outer.extractfile(path.relative_to(stage).as_posix()).read() == path.read_bytes()
            with tarfile.open(fileobj=io.BytesIO(outer.extractfile('app.tgz').read()), mode='r:gz') as inner:
                members = {m.name.removeprefix('./'): m for m in inner.getmembers() if m.isfile()}
                expected = {p.relative_to(stage / 'app').as_posix(): p for p in (stage / 'app').rglob('*') if p.is_file()}
                assert set(members) == set(expected), ('unexpected payload files', sorted(set(members) - set(expected)), 'missing', sorted(set(expected) - set(members)))
                for name, path in expected.items():
                    assert inner.extractfile(members[name]).read() == path.read_bytes(), name
                    assert members[name].mode & 0o777 == path.stat().st_mode & 0o777, name
        # Copy with exclusive creation only after all verification succeeded.
        with final.open('xb') as out, produced.open('rb') as src:
            shutil.copyfileobj(src, out)
    checksum = digest(final)
    Path(str(final) + '.sha256').write_text(checksum + '  ' + final.name + '\n')
    print(json.dumps({'file': str(final), 'bytes': final.stat().st_size, 'sha256': checksum}))


if __name__ == '__main__':
    main()
