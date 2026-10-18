#!/usr/bin/env python3
"""Inspect real native SDK execution, package identity and optional free ports."""
import grp
import json
import os
import pwd
import re

from native_checks import CheckError, JsonParser, checked, emit, executable, port_free, port_number, run

PYTHON_PROBE = (
    'import sys,json,platform,ssl,ctypes; '
    'print(json.dumps({"version":list(sys.version_info[:3]),'
    '"machine":platform.machine(),"bits":8*ctypes.sizeof(ctypes.c_void_p),'
    '"ssl":ssl.OPENSSL_VERSION}))'
)


def python_probe(path, required):
    resolved = executable(path)
    value = json.loads(run([str(resolved), '-I', '-B', '-S', '-c', PYTHON_PROBE]))
    version = value['version']
    if not isinstance(version, list) or len(version) != 3 or any(type(v) is not int for v in version):
        raise CheckError('Python returned invalid version metadata')
    if required and version[:2] != [int(v) for v in required.split('.')]:
        raise CheckError('Python version does not match ' + required)
    if value.get('bits') not in (32, 64) or not value.get('ssl'):
        raise CheckError('Python native ABI probe failed')
    return {'path': str(resolved), **value, 'site_packages_executed': False}


def node_probe(path, required):
    resolved = executable(path)
    version = run([str(resolved), '--version']).strip()
    match = re.fullmatch(r'v(\d+)\.(\d+)\.(\d+)', version)
    if not match:
        raise CheckError('Node returned invalid version metadata')
    if required is not None and int(match[1]) != required:
        raise CheckError('Node major does not match ' + str(required))
    return {'path': str(resolved), 'version': version}


def identity_probe(username, groupname):
    user = pwd.getpwnam(username)
    group = grp.getgrnam(groupname)
    if user.pw_uid == 0 or group.gr_gid == 0:
        raise CheckError('Package identity must not be root')
    return {'username': username, 'uid': user.pw_uid, 'primary_gid': user.pw_gid,
            'package_group': groupname, 'package_gid': group.gr_gid,
            'note': 'TRIM_GID is the dedicated package group, not primary_gid'}


def free_probe(port):
    if not port_free(port):
        raise CheckError('Port is occupied; inspect ownership before an install or upgrade')
    return {'port': port, 'free': True}


def main(argv=None):
    parser = JsonParser(description=__doc__)
    parser.add_argument('--python')
    parser.add_argument('--python-version')
    parser.add_argument('--node')
    parser.add_argument('--node-major', type=int)
    parser.add_argument('--identity')
    parser.add_argument('--group')
    parser.add_argument('--port', type=port_number, action='append', default=[])
    args = parser.parse_args(argv)
    if not any((args.python, args.node, args.identity, args.port)):
        parser.error('Supply at least one runtime, identity or port probe')
    if args.python_version and (not args.python or not re.fullmatch(r'\d+\.\d+', args.python_version)):
        parser.error('--python-version requires --python and a major.minor version')
    if args.node_major is not None and (not args.node or args.node_major < 1):
        parser.error('--node-major requires --node and a positive major version')
    if bool(args.identity) != bool(args.group):
        parser.error('--identity and --group must be supplied together')
    report = {'ok': False, 'checks': {}, 'issues': [], 'read_only': True}
    if args.python:
        checked(report, 'python', lambda: python_probe(args.python, args.python_version))
    if args.node:
        checked(report, 'node', lambda: node_probe(args.node, args.node_major))
    if args.identity:
        checked(report, 'identity', lambda: identity_probe(args.identity, args.group))
    for port in args.port:
        checked(report, 'port_' + str(port), lambda p=port: free_probe(p))
    return emit(report)


if __name__ == '__main__':
    raise SystemExit(main())
