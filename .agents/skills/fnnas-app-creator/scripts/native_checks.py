"""Read-only primitives shared by native fnOS probes."""
import argparse
import errno
import json
import os
from pathlib import Path
import socket
import subprocess

ENV = {'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'LANG': 'C.UTF-8'}


class CheckError(ValueError):
    pass


class JsonParser(argparse.ArgumentParser):
    def error(self, message):
        print(json.dumps({'ok': False, 'issues': [message]}, ensure_ascii=False))
        raise SystemExit(2)


def run(args, timeout=15):
    try:
        result = subprocess.run(args, cwd='/', env=ENV, capture_output=True,
                                text=True, timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise CheckError('Command inspection failed: ' + type(exc).__name__) from exc
    if result.returncode:
        raise CheckError('Command returned exit code ' + str(result.returncode))
    if len(result.stdout) > 131072:
        raise CheckError('Command output exceeded the inspection bound')
    return result.stdout


def executable(value):
    path = Path(value)
    if not path.is_absolute():
        raise CheckError('Executable path must be absolute')
    resolved = path.resolve(strict=True)
    if not resolved.is_file() or not os.access(resolved, os.X_OK):
        raise CheckError('Executable is missing or not executable')
    return resolved


def port_number(value):
    try:
        port = int(value)
    except (TypeError, ValueError) as exc:
        raise argparse.ArgumentTypeError('Port must be an integer') from exc
    if not 1 <= port <= 65535:
        raise argparse.ArgumentTypeError('Port must be between 1 and 65535')
    return port


def port_free(port):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        try:
            sock.bind(('0.0.0.0', port))
        except OSError as exc:
            if exc.errno == errno.EADDRINUSE:
                return False
            raise CheckError('Port inspection failed: errno=' + str(exc.errno)) from exc
    return True


def checked(report, name, probe):
    try:
        report['checks'][name] = probe()
    except (CheckError, OSError, ValueError, KeyError, TypeError) as exc:
        report['issues'].append(name + ': ' + str(exc))


def emit(report):
    report['ok'] = not report['issues']
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report['ok'] else 1
