#!/usr/bin/env python3
"""Metadata-resident, unprivileged fnOS lifecycle for v2rayA 2.5.13."""
import fcntl
import grp
import http.client
import json
import os
from pathlib import Path
import pwd
import re
import shlex
import signal
import socket
import stat
import subprocess
import sys
import time

PYTHON = '/var/apps/python312/target/bin/python3.12'
PORT = 2017
VERSION = '2.5.13'
PROC = Path('/proc')
MARKER = 'fnos-initialized.json'
PHASES = {'start', 'stop', 'status', 'install_init', 'install_callback',
          'upgrade_init', 'upgrade_callback', 'uninstall_init',
          'uninstall_callback', 'config_init', 'config_callback'}
DEFAULTS = {'transparent': 'close', 'dnsMode': 'off',
            'pacAutoUpdateMode': 'none', 'subscriptionAutoUpdateMode': 'none'}


def path(name):
    p = Path(os.environ[name])
    if not p.is_absolute() or p in map(Path, ('/', '/tmp', '/var', '/var/apps')):
        raise RuntimeError('invalid application path')
    return p.resolve(strict=True)


def identity():
    user, group = pwd.getpwnam('v2raya'), grp.getgrnam('v2raya')
    if user.pw_uid == 0 or group.gr_gid == 0 or os.geteuid() != user.pw_uid:
        raise RuntimeError('v2raya nonroot package identity required')
    if int(os.environ['TRIM_UID']) != user.pw_uid or int(os.environ['TRIM_GID']) != group.gr_gid:
        raise RuntimeError('package UID/GID mismatch')
    if os.environ.get('TRIM_USERNAME', 'v2raya') != 'v2raya' or os.environ.get('TRIM_GROUPNAME', 'v2raya') != 'v2raya':
        raise RuntimeError('package name mismatch')
    if os.getegid() != group.gr_gid:
        if os.environ.get('_V2RAYA_GROUP_REEXEC') == '1':
            raise RuntimeError('dedicated group unavailable')
        os.environ['_V2RAYA_GROUP_REEXEC'] = '1'
        command = shlex.join([PYTHON, '-I', '-B', str(Path(__file__).resolve()), *sys.argv[1:]])
        os.execv('/usr/bin/sg', ['sg', 'v2raya', '-c', command])
    return user.pw_uid, group.gr_gid


def private_dir(p):
    if p.is_symlink():
        raise RuntimeError('private directory cannot be a symlink')
    p.mkdir(mode=0o700, exist_ok=True)
    info = p.stat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid():
        raise RuntimeError('private directory ownership mismatch')
    p.chmod(0o700)
    return p


def private_file(p, mode='a'):
    flags = os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CREAT
    flags |= os.O_WRONLY | (os.O_APPEND if mode == 'a' else 0)
    fd = os.open(p, flags, 0o600)
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_nlink != 1:
        os.close(fd)
        raise RuntimeError('private file ownership or type mismatch')
    os.fchmod(fd, 0o600)
    if mode == 'w':
        os.ftruncate(fd, 0)
    return os.fdopen(fd, mode)


def argv_for(root, etc, sock=None):
    args = [str(root / 'bin/v2raya'), '--lite',
            '--address=' + ('127.0.0.1' if sock else '0.0.0.0') + ':' + str(PORT)]
    if sock:
        args.append('--socket=' + str(sock))
    return args + ['--config=' + str(etc), '--v2ray-bin=' + str(root / 'bin/v2raya_core'),
                   '--v2ray-assetsdir=' + str(root / 'share'), '--log-disable-color']


def snapshot(pid):
    try:
        p = PROC / str(pid)
        fields = dict(line.split(':', 1) for line in (p / 'status').read_text().splitlines() if ':' in line)
        if fields['State'].strip().startswith('Z'):
            return None
        values = (p / 'stat').read_text().rsplit(')', 1)[1].split()
        return {'uid': list(map(int, fields['Uid'].split())),
                'gid': list(map(int, fields['Gid'].split())),
                'argv': (p / 'cmdline').read_bytes().rstrip(b'\0').split(b'\0'),
                'exe': os.readlink(p / 'exe').removesuffix(' (deleted)'),
                'stamp': values[19], 'group': int(values[2]), 'parent': int(values[1])}
    except (FileNotFoundError, ProcessLookupError):
        return None
    except PermissionError:
        # Other users' /proc entries are normally unreadable. For our own UID,
        # lack of executable proof is an inspection failure, never 'stopped'.
        if 'fields' in locals() and fields.get('Uid', '').split() == [str(os.geteuid())] * 4:
            raise RuntimeError('cannot inspect package process executable')
        return None


def process(pid, root, etc, uid, gid, sock=None):
    s = snapshot(pid)
    if not s or s['uid'] != [uid] * 4 or s['gid'] != [gid] * 4:
        return None
    contracts = [('service', argv_for(root, etc)),
                 ('core', [str(root / 'bin/v2raya_core'), 'run', '--config=' + str(etc / 'config.json')])]
    if sock:
        contracts.append(('bootstrap', argv_for(root, etc, sock)))
    for kind, args in contracts:
        if s['exe'] == args[0] and s['argv'] == list(map(os.fsencode, args)):
            return dict(s, kind=kind)
    return None


def owned(root, etc, uid, gid, sock=None):
    matches = {}
    for p in PROC.iterdir():
        if p.name.isdecimal():
            s = process(int(p.name), root, etc, uid, gid, sock)
            if s:
                matches[int(p.name)] = s
    return matches


def listening():
    for name in ('tcp', 'tcp6'):
        for line in (PROC / 'net' / name).read_text().splitlines()[1:]:
            fields = line.split()
            if fields[3] == '0A' and int(fields[1].split(':')[1], 16) == PORT:
                return True
    return False


def wait_until(predicate, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(.1)
    return predicate()


def signal_exact(pid, expected, signum):
    # pidfd binds the signal to the inspected process, not a recycled PID.
    try:
        fd = os.pidfd_open(pid)
    except ProcessLookupError:
        return
    try:
        current = snapshot(pid)
        if current and all(current[k] == expected[k] for k in ('uid', 'gid', 'argv', 'exe', 'stamp', 'group')):
            signal.pidfd_send_signal(fd, signum)
    except ProcessLookupError:
        pass
    finally:
        os.close(fd)


def stop(root, etc, state, uid, gid, sock=None, check_port=True):
    targets = owned(root, etc, uid, gid, sock)
    groups = {s['group'] for s in targets.values() if s['kind'] in ('service', 'bootstrap')}
    # Never killpg: even a verified service group can contain an unrelated child.
    # Version probes are the only additional upstream child contract.
    for p in PROC.iterdir():
        if not p.name.isdecimal() or int(p.name) in targets:
            continue
        s = snapshot(int(p.name))
        if not s or s['group'] not in groups:
            continue
        expected = [os.fsencode(root / 'bin/v2raya_core'), b'version']
        if s['uid'] == [uid] * 4 and s['gid'] == [gid] * 4 and s['exe'] == str(root / 'bin/v2raya_core') and s['argv'] == expected:
            targets[int(p.name)] = s
        else:
            raise RuntimeError('unverified process-group member; no broad cleanup performed')
    for sig, timeout in ((signal.SIGTERM, 15), (signal.SIGKILL, 5)):
        for pid, s in targets.items():
            signal_exact(pid, s, sig)
        if wait_until(lambda: all((snapshot(p) or {}).get('stamp') != s['stamp'] for p, s in targets.items()), timeout):
            break
    if owned(root, etc, uid, gid, sock):
        raise RuntimeError('verified v2rayA process remains after stop')
    if check_port and not wait_until(lambda: not listening(), 3):
        raise RuntimeError('port 2017 occupied by an unverified listener')
    (state / 'v2raya.pid.json').unlink(missing_ok=True)


class UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, address):
        super().__init__('localhost', timeout=3)
        self.address = str(address)

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.address)


def api(route, method='GET', body=None, token=None, sock=None):
    conn = UnixHTTPConnection(sock) if sock else http.client.HTTPConnection('127.0.0.1', PORT, timeout=3)
    try:
        headers = {'Content-Type': 'application/json'}
        if token:
            headers['Authorization'] = 'Bearer ' + token
        conn.request(method, '/api/' + route, None if body is None else json.dumps(body).encode(), headers)
        response = conn.getresponse()
        raw = response.read(1048577)
        if response.status != 200 or len(raw) > 1048576:
            raise RuntimeError('API request failed')
        data = json.loads(raw)
        if data.get('code') != 'SUCCESS':
            raise RuntimeError('API rejected request')
        return data.get('data')
    finally:
        conn.close()


def health(sock=None, accounts=True):
    try:
        data = api('version', sock=sock)
        expected = {'version': VERSION, 'lite': 1, 'isRoot': False, 'variant': 'V2rayaCore',
                    'serviceValid': True, 'coreVersionValid': True, 'coreVersion': VERSION,
                    'hasAccounts': accounts}
        return all(type(data.get(k)) is type(v) and data[k] == v for k, v in expected.items())
    except (OSError, ValueError, TypeError, RuntimeError, http.client.HTTPException):
        return False


def credentials():
    username = os.environ.get('wizard_v2raya_username', '')
    password = os.environ.get('wizard_v2raya_password', '')
    if not re.fullmatch(r'[A-Za-z0-9_.@-]{3,64}', username):
        raise RuntimeError('administrator username must contain 3-64 safe ASCII characters')
    if not 12 <= len(password.encode('utf-8')) <= 32 or any(ord(c) < 32 or ord(c) == 127 for c in password):
        raise RuntimeError('administrator password must contain 12-32 UTF-8 bytes without controls')
    return {'username': username, 'password': password}


def initialized(etc):
    marker = etc / MARKER
    if marker.is_symlink():
        raise RuntimeError('initialization marker cannot be a symlink')
    if marker.exists():
        info = marker.stat()
        if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o600 or not stat.S_ISREG(info.st_mode):
            raise RuntimeError('initialization marker permissions invalid')
        database = etc / 'v2raya.db'
        if marker.read_text() != '{"schema":1,"application":"v2raya"}\n' or database.is_symlink() or not database.is_file():
            raise RuntimeError('initialization marker or database invalid')
        return True
    if any(etc.iterdir()):
        raise RuntimeError('existing configuration without package initialization marker; refusing unknown administrator')
    return False


def preflight(root):
    for name in ('bin/v2raya', 'bin/v2raya_core', 'share/geoip.dat', 'share/geosite.dat'):
        p = root / name
        if p.is_symlink() or not p.is_file() or p.stat().st_size == 0 or not os.access(p, os.R_OK):
            raise RuntimeError('required native binary or offline geo asset is missing or unreadable')
        if name.startswith('bin/') and not os.access(p, os.X_OK):
            raise RuntimeError('native binary is not executable')
        with p.open('rb') as stream:
            if not stream.read(1):
                raise RuntimeError('empty native asset')


def spawn(root, etc, var, sock=None):
    # A small explicit environment prevents V2RAYA_*, proxies and wizard values
    # from overriding flags, running hooks, or leaking into child processes.
    env = {'PATH': '/usr/bin:/bin', 'HOME': str(path('TRIM_PKGHOME')),
           'TMPDIR': str(path('TRIM_PKGTMP')), 'LANG': 'C.UTF-8'}
    with private_file(var / 'logs/v2raya.log') as log:
        return subprocess.Popen(argv_for(root, etc, sock), cwd=var, env=env,
                                stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)


def ready(child, root, etc, uid, gid, sock=None, accounts=True):
    deadline = time.monotonic() + 45
    while time.monotonic() < deadline:
        code = child.poll()
        if code is not None:
            raise subprocess.CalledProcessError(code if code > 0 else 1, 'v2raya')
        if process(child.pid, root, etc, uid, gid, sock) is None:
            observed = snapshot(child.pid)
            # Linux can expose the new executable with an empty cmdline while
            # exec is still faulting argv pages in (observed on WSL/DrvFS).
            # Wait only for this precise transient; never accept another argv.
            if observed and observed['argv'] in ([b''], list(map(os.fsencode, argv_for(root, etc, sock)))) and observed['exe'] == str(root / 'bin/v2raya') and observed['uid'] == [uid] * 4 and observed['gid'] == [gid] * 4:
                time.sleep(.05)
                continue
            raise RuntimeError('spawned service identity mismatch')
        if health(sock, accounts):
            return
        time.sleep(.2)
    raise RuntimeError('API readiness timeout; inspect private application log')


def prepare(root, etc, var, state, uid, gid, sock):
    preflight(root)
    exists = initialized(etc)
    secret = None if exists else credentials()
    if owned(root, etc, uid, gid, sock):
        raise RuntimeError('stop existing service before private initialization')
    if len(os.fsencode(sock)) >= 108:
        raise RuntimeError('private bootstrap socket path exceeds Unix limit')
    child = spawn(root, etc, var, sock)
    success = False
    try:
        ready(child, root, etc, uid, gid, sock, accounts=exists)
        if api('account', sock=sock).get('hasAnyAccounts') is not exists:
            raise RuntimeError('unexpected account state; refusing initialization')
        if not exists:
            token = api('account', 'POST', secret, sock=sock).get('token')
            login = api('login', 'POST', secret, sock=sock).get('token')
            if not isinstance(token, str) or not token or not isinstance(login, str) or not login:
                raise RuntimeError('administrator login verification failed')
            api('setting', 'PUT', DEFAULTS, token=login, sock=sock)
            settings = api('setting', token=login, sock=sock)['setting']
            if any(settings.get(k) != v for k, v in DEFAULTS.items()):
                raise RuntimeError('safe initial settings verification failed')
        if api('account', sock=sock).get('hasAnyAccounts') is not True or not health(sock):
            raise RuntimeError('administrator verification failed')
        success = True
    except BaseException:
        try:
            stop(root, etc, state, uid, gid, sock, check_port=False)
            child.wait(timeout=5)
            sock.unlink(missing_ok=True)
        except Exception:
            print('v2rayA bootstrap cleanup failed; original failure retained', file=sys.stderr)
        raise
    else:
        stop(root, etc, state, uid, gid, sock, check_port=False)
        child.wait(timeout=5)
        sock.unlink(missing_ok=True)
    if success and not exists:
        with private_file(etc / MARKER, 'w') as output:
            output.write('{"schema":1,"application":"v2raya"}\n')
            output.flush()
            os.fsync(output.fileno())


def start(root, etc, var, state, uid, gid, sock):
    matches = owned(root, etc, uid, gid, sock)
    if matches:
        services = [s for s in matches.values() if s['kind'] == 'service']
        if initialized(etc) and len(services) == 1 and all(s['kind'] != 'bootstrap' for s in matches.values()) and health():
            return
        raise RuntimeError('existing service is not healthy; stop before retry')
    if listening():
        raise RuntimeError('port 2017 is occupied by an unverified listener')
    prepare(root, etc, var, state, uid, gid, sock)
    child = spawn(root, etc, var)
    try:
        ready(child, root, etc, uid, gid)
        s = process(child.pid, root, etc, uid, gid)
        with private_file(state / 'v2raya.pid.json', 'w') as output:
            json.dump({'pid': child.pid, 'starttime': s['stamp']}, output)
    except BaseException:
        try:
            stop(root, etc, state, uid, gid, sock)
            child.wait(timeout=5)
        except Exception:
            print('v2rayA startup cleanup failed; original failure retained', file=sys.stderr)
        raise


def main():
    os.umask(0o077)
    uid, gid = identity()
    phase = sys.argv[1] if len(sys.argv) == 2 else ''
    if phase not in PHASES:
        raise RuntimeError('unsupported lifecycle action')
    if phase in ('install_init', 'config_init', 'uninstall_callback'):
        # Pre-install and post-removal do not rely on target availability.
        return 0
    root, var = path('TRIM_APPDEST'), path('TRIM_PKGVAR')
    etc = private_dir(path('TRIM_PKGETC') / 'v2raya')
    state = private_dir(var / 'run')
    private_dir(var / 'logs')
    sock = private_dir(path('TRIM_PKGTMP') / 'bootstrap') / 'bootstrap.sock'
    with private_file(state / 'lifecycle.lock') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if phase in ('stop', 'upgrade_init', 'uninstall_init'):
            stop(root, etc, state, uid, gid, sock)
        elif phase == 'upgrade_callback':
            stop(root, etc, state, uid, gid, sock)
            prepare(root, etc, var, state, uid, gid, sock)
        elif phase in ('install_callback', 'config_callback'):
            prepare(root, etc, var, state, uid, gid, sock)
        elif phase == 'start':
            start(root, etc, var, state, uid, gid, sock)
        elif phase == 'status':
            matches = owned(root, etc, uid, gid, sock)
            if not matches:
                return 1 if listening() else 3
            services = [s for s in matches.values() if s['kind'] == 'service']
            return 0 if len(services) == 1 and initialized(etc) and health() else 1
    return 0


def report(error):
    reason = str(error) if type(error) is RuntimeError else 'runtime command or inspection failed'
    message = 'v2rayA lifecycle failed: ' + reason + '.'
    print(message, file=sys.stderr)
    name = os.environ.get('TRIM_TEMP_LOGFILE')
    if name and os.geteuid() != 0:
        try:
            fd = os.open(name, os.O_WRONLY | os.O_APPEND | os.O_NOFOLLOW | os.O_NONBLOCK)
            if not stat.S_ISREG(os.fstat(fd).st_mode):
                os.close(fd)
                return
            with os.fdopen(fd, 'a') as output:
                output.write(message + '\n')
        except OSError:
            pass


if __name__ == '__main__':
    try:
        sys.exit(main())
    except subprocess.CalledProcessError as error:
        report(error)
        sys.exit(error.returncode if error.returncode > 0 else 1)
    except Exception as error:
        report(error)
        sys.exit(1)
