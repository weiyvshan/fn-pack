#!/usr/bin/env python3
"""Opt-in real-core probe. Run ONLY inside a fresh network namespace.

Example (WSL root creates an isolated namespace, child core stays nonroot):
  unshare --net python3 -B tests/probe-tun-capabilities.py /absolute/v2raya_core
No files with capabilities, users, host routes or system services are changed.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('core', type=Path)
    args = parser.parse_args()
    assert os.geteuid() == 0, 'namespace test orchestrator requires root'
    assert os.readlink('/proc/self/ns/net') != os.readlink('/proc/1/ns/net'), 'refusing host network namespace'
    devices = json.loads(subprocess.check_output(['ip', '-j', 'link', 'show']))
    assert {d['ifname'] for d in devices} == {'lo'}, 'requires fresh netns with only loopback'
    assert not subprocess.check_output(['ip', 'route', 'show']).strip(), 'namespace must have no routes'
    core = args.core.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix='v2raya-tun-cap-') as directory:
        base = Path(directory)
        base.chmod(0o755)
        config = base / 'config.json'
        config.write_text(json.dumps({'log': {'loglevel': 'warning'}, 'inbounds': [
            {'protocol': 'tun-mips', 'tag': 'transparent', 'settings':
             {'name': 'tun0', 'mtu': 1500, 'address4': '10.0.85.2/30'}}],
            'outbounds': [{'protocol': 'freedom', 'tag': 'direct'}]}))
        config.chmod(0o644)
        for caps, expected in [('-all', False), ('-all,+net_admin', True)]:
            with (base / 'core.log').open('wb') as log:
                child = subprocess.Popen(['setpriv', '--reuid=65534', '--regid=65534',
                    '--clear-groups', '--inh-caps=' + caps, '--ambient-caps=' + caps,
                    str(core), 'run', '--config=' + str(config)],
                    stdin=subprocess.DEVNULL, stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 5
                present = False
                while time.monotonic() < deadline:
                    present = subprocess.run(['ip', 'link', 'show', 'tun0'],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
                    if present or child.poll() is not None:
                        break
                    time.sleep(.05)
                assert present is expected, 'unexpected TUN capability result'
                if expected:
                    status = dict(line.split(':', 1) for line in Path(f'/proc/{child.pid}/status').read_text().splitlines() if ':' in line)
                    assert status['Uid'].split() == ['65534'] * 4
                    assert int(status['CapEff'], 16) == 1 << 12, 'unexpected extra effective capability'
                else:
                    child.wait(timeout=5)
                    assert child.returncode != 0
                print(json.dumps({'capabilities': caps, 'tun_created': present, 'nonroot_uid': 65534}))
            finally:
                if child.poll() is None:
                    child.terminate()
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait(timeout=5)
            assert subprocess.run(['ip', 'link', 'show', 'tun0'], stdout=subprocess.DEVNULL,
                                  stderr=subprocess.DEVNULL).returncode != 0, 'TUN remained after core exit'
    print('PASS: core-only CAP_NET_ADMIN creates TUN; device removed after exit; host namespace untouched')


if __name__ == '__main__':
    main()
