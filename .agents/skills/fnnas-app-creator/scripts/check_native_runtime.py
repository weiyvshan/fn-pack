#!/usr/bin/env python3
"""Inspect systemd, kernel process identity, socket ownership and loopback health."""
import grp
import json
import os
from pathlib import Path
import pwd
import re
import urllib.error
import urllib.parse
import urllib.request

from native_checks import CheckError, JsonParser, checked, emit, port_free, port_number, run

PROPERTIES = ('LoadState', 'ActiveState', 'SubState', 'MainPID', 'Type', 'User', 'Group')


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file_pointer, code, message, headers, new_url):
        raise CheckError('Health redirects are not evidence for the local service')


def unit_snapshot(unit):
    output = run(['/usr/bin/systemctl', 'show', unit, '--no-pager',
                  '--property=' + ','.join(PROPERTIES)])
    values = {}
    for line in output.splitlines():
        if '=' in line:
            key, value = line.split('=', 1)
            if key in values:
                raise CheckError('Duplicate systemd property')
            values[key] = value
    if any(key not in values for key in PROPERTIES):
        raise CheckError('Incomplete systemd inspection')
    if values['LoadState'] != 'loaded':
        raise CheckError('Unit is not loaded')
    return values


def metadata_identity(values, uid, gid):
    user_value, group_value = values['User'], values['Group']
    actual_uid = int(user_value) if user_value.isdigit() else pwd.getpwnam(user_value).pw_uid
    actual_gid = int(group_value) if group_value.isdigit() else grp.getgrnam(group_value).gr_gid
    if (actual_uid, actual_gid) != (uid, gid):
        raise CheckError('Unit User/Group differs from the requested identity')
    if values['Type'] != 'exec':
        raise CheckError('Unit must use Type=exec before strict PID verification')
    return {'uid': actual_uid, 'gid': actual_gid, 'type': values['Type']}


def process_probe(pid, uid, gid, expected_exe, tokens, proc_root=Path('/proc')):
    process = proc_root / str(pid)
    fields = {}
    for line in (process / 'status').read_text().splitlines():
        if line.startswith(('Uid:', 'Gid:')):
            name, value = line.split(':', 1)
            fields[name] = [int(v) for v in value.split()]
    if fields.get('Uid') != [uid] * 4 or fields.get('Gid') != [gid] * 4:
        raise CheckError('All real/effective/saved/filesystem IDs must match the package identity')
    argv = (process / 'cmdline').read_bytes().split(b'\0')
    argv = [v.decode('utf-8', errors='strict') for v in argv if v]
    if not argv or any(token not in argv for token in tokens):
        raise CheckError('Process argv differs from the requested command tokens')
    raw_stat = (process / 'stat').read_text()
    tail = raw_stat[raw_stat.rfind(')') + 1:].split()
    if len(tail) < 20 or not tail[19].isdigit():
        raise CheckError('Kernel process start-time inspection is invalid')
    start_time = int(tail[19])
    actual_exe = os.readlink(process / 'exe')
    if actual_exe.endswith(' (deleted)'):
        raise CheckError('Process still uses a replaced executable')
    if expected_exe and Path(actual_exe).resolve(strict=True) != Path(expected_exe).resolve(strict=True):
        raise CheckError('Process executable differs from the requested SDK')
    return {'pid': pid, 'uids': fields['Uid'], 'gids': fields['Gid'],
            'exe': actual_exe, 'start_time': start_time, 'required_argv_present': True}


def socket_probe(port, pid):
    output = run(['/usr/bin/ss', '-H', '-ltnp', 'sport = :' + str(port)])
    if not output.strip():
        raise CheckError('Expected TCP listener is absent')
    owners = sorted({int(v) for v in re.findall(r'\bpid=(\d+)', output)})
    if not owners:
        raise CheckError('Socket owner inspection is unavailable; use read-only process inspection privileges')
    if any(pid not in {int(v) for v in re.findall(r'\bpid=(\d+)', line)}
           for line in output.splitlines() if line.strip()):
        raise CheckError('A TCP listener on this port does not belong to the verified MainPID')
    return {'port': port, 'owner_pids': owners, 'main_pid_owns_listener': True}


def health_probe(url, port, key, expected):
    parsed = urllib.parse.urlsplit(url)
    if (parsed.scheme not in ('http', 'https') or parsed.hostname not in ('127.0.0.1', '::1')
            or parsed.username is not None or parsed.password is not None or parsed.fragment or parsed.query):
        raise CheckError('Health URL must be credential-free literal loopback without query or fragment')
    selected_port = parsed.port or (443 if parsed.scheme == 'https' else 80)
    if selected_port != port:
        raise CheckError('Health URL must use the verified service port')
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    try:
        with opener.open(url, timeout=5) as response:
            if response.status != 200:
                raise CheckError('Health HTTP status is not 200')
            data = response.read(16385)
    except urllib.error.URLError as exc:
        raise CheckError('Health request failed: ' + type(exc).__name__) from exc
    if len(data) > 16384:
        raise CheckError('Health response exceeded the bound')
    value = json.loads(data)
    if not isinstance(value, dict) or value.get(key) != expected:
        raise CheckError('Health semantic value does not match')
    return {'http_status': 200, 'semantic_key': key, 'semantic_value': expected}


def inspect(args):
    report = {'ok': False, 'checks': {}, 'issues': [], 'read_only': True}
    try:
        before = unit_snapshot(args.unit)
        pid = int(before['MainPID'])
        if args.state == 'running':
            if (before['ActiveState'], before['SubState']) != ('active', 'running') or pid < 1:
                raise CheckError('Unit is not active/running with a positive MainPID')
        elif (before['ActiveState'], before['SubState'], pid) != ('inactive', 'dead', 0):
            raise CheckError('Stopped unit must be inactive/dead with MainPID=0')
        report['checks']['unit'] = {'name': args.unit, **before}
    except (CheckError, OSError, ValueError) as exc:
        report['issues'].append('unit: ' + str(exc))
        return report
    checked(report, 'unit_identity', lambda: metadata_identity(before, args.uid, args.gid))
    if args.state == 'running':
        checked(report, 'process', lambda: process_probe(pid, args.uid, args.gid, args.exe, args.argv_token))
        checked(report, 'socket', lambda: socket_probe(args.port, pid))
        checked(report, 'health', lambda: health_probe(args.health_url, args.port, args.health_key, args.health_value))
    else:
        def stopped_socket():
            if not port_free(args.port):
                raise CheckError('Stopped unit left its service port occupied')
            return {'port': args.port, 'free': True}
        checked(report, 'socket', stopped_socket)
    try:
        after = unit_snapshot(args.unit)
        if after != before:
            raise CheckError('Unit changed during inspection; take a fresh snapshot')
        if args.state == 'running' and 'process' in report['checks']:
            current = process_probe(pid, args.uid, args.gid, args.exe, args.argv_token)
            if current != report['checks']['process']:
                raise CheckError('Process identity or kernel start-time changed during inspection')
        report['checks']['stable_unit_snapshot'] = True
    except (CheckError, OSError, ValueError) as exc:
        report['issues'].append('stable_unit_snapshot: ' + str(exc))
    return report


def main(argv=None):
    parser = JsonParser(description=__doc__)
    parser.add_argument('--unit', required=True)
    parser.add_argument('--uid', type=int, required=True)
    parser.add_argument('--gid', type=int, required=True)
    parser.add_argument('--port', type=port_number, required=True)
    parser.add_argument('--state', choices=('running', 'stopped'), default='running')
    parser.add_argument('--exe')
    parser.add_argument('--argv-token', action='append', default=[])
    parser.add_argument('--health-url')
    parser.add_argument('--health-key', default='status')
    parser.add_argument('--health-value', default='healthy')
    args = parser.parse_args(argv)
    if not re.fullmatch(r'[A-Za-z0-9_.@-]+\.service', args.unit):
        parser.error('--unit must be one exact service unit name')
    if args.uid < 1 or args.gid < 1:
        parser.error('Expected package UID and GID must be non-root')
    if args.exe and not Path(args.exe).is_absolute():
        parser.error('--exe must be absolute')
    if args.state == 'running' and (not args.exe or not args.argv_token or not args.health_url):
        parser.error('Running verification requires --exe, --argv-token and --health-url')
    if args.state == 'stopped' and (args.exe or args.argv_token or args.health_url):
        parser.error('Stopped verification does not use exe, argv or health parameters')
    return emit(inspect(args))


if __name__ == '__main__':
    raise SystemExit(main())
