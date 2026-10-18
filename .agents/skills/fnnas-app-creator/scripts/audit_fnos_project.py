#!/usr/bin/env python3
"""Static audit for fnOS application packages.

Debian-native replacement for the former audit_fnos_project.ps1. It emits the
same JSON contract and text report, so every existing caller and the bundled
regression test keep working:

    {status, project, appname,
     summary: {high, medium, low, info, total},
     inventory: {package_bytes, elf, elf_machines, dll, shared_objects, pdb,
                 runtime_bytes, license_files, docker_projects,
                 wizard_port_fields},
     findings: [{severity, code, message, path, line, evidence}]}

PowerShell's -match is case-insensitive, so every pattern below is applied
case-insensitively as well.
"""

from __future__ import annotations

import argparse
import ast
import copy
import hashlib
import json
import os
import re
import sys
from collections import Counter
from pathlib import Path
from typing import Any, Iterator, List, Optional

SEVERITY_RANK = {"High": 0, "Medium": 1, "Low": 2, "Info": 3}
OPEN_API_MINIMUM_VERSION = "1.2.0401"
MAX_CODE_FILE_BYTES = 2 * 1024 * 1024
MAX_LIFECYCLE_FILE_BYTES = 1024 * 1024

CODE_EXTENSIONS = {
    ".bash", ".cjs", ".cgi", ".go", ".htm", ".html", ".java",
    ".js", ".jsx", ".mjs", ".php", ".py", ".rb", ".rs", ".sh",
    ".svelte", ".ts", ".tsx", ".vue",
}
EXCLUDED_SEGMENTS = {
    ".git", ".pnpm-store", ".research", ".tmp", "__pycache__",
    "node_modules", "vendor",
}
EXCLUDED_TOP_LEVEL = {
    "build", "docs", "evals", "examples", "patches", "scripts",
    "test", "tests",
}
FRONTEND_SEGMENTS = {"frontend", "public", "ui", "web", "www"}

BACKEND_API_PATTERN = r"TRIM_API_TOKEN|/api/v1/trimapp|trim_open_gateway_apiscope\.socket"
SDK_PATTERN = r"@trimjs/web-app|\bnew\s+TrimApp\s*\("
SCOPE_USAGE_RULES = (
    ("trim.file.sharedAccess",
     r"\b(?:pickSharedFile|authorizeSharedFile)\s*\(|trim\.file\.(?:getSharedAccessibleFolders|delSharedAccessibleFolder)\b"),
    ("trim.file.userAccess",
     r"\b(?:pickUserFile|authorizeUserFile)\s*\(|trim\.file\.(?:getUserAccessibleFolders|delUserAccessibleFolder)\b"),
    ("trim.file.userAcl", r"trim\.file\.checkUserACL\b"),
    ("trim.file.path", r"trim\.file\.convertPath\b"),
    ("trim.system.getPlatformConfig", r"trim\.system\.getPlatformConfig\b"),
)
TOKEN_LOGGING_PATTERN = (
    r"(?:console\.(?:log|info|warn|error)|\bprint\s*\(|\becho\b|\bprintf\b|logger\.\w+)"
    r"[^\r\n]*TRIM_API_TOKEN|TRIM_API_TOKEN[^\r\n]*"
    r"(?:console\.(?:log|info|warn|error)|\bprint\s*\(|\becho\b|\bprintf\b|logger\.\w+)"
)
TOKEN_PERSISTENCE_PATTERN = (
    r"(?:writeFile(?:Sync)?|appendFile(?:Sync)?|write_text|localStorage|sessionStorage|database|insert)"
    r"[^\r\n]*TRIM_API_TOKEN|TRIM_API_TOKEN[^\r\n]*"
    r"(?:writeFile(?:Sync)?|appendFile(?:Sync)?|write_text|localStorage|sessionStorage|database|insert|>>|>\s*[^&])"
)
IDENTITY_ASSIGNMENT_PATTERN = (
    r"(?:const|let|var)?\s*(?:uid|userId|isAdmin|username)\s*=\s*"
    r"(?:req\.(?:query|body|params)|message|payload)(?:\.|\[)"
)
IDENTITY_DESTRUCTURE_PATTERN = (
    r"\{[^}\r\n]*(?:uid|userId|isAdmin|username)[^}\r\n]*\}\s*=\s*"
    r"(?:req\.(?:query|body|params)|message|payload)\b"
)


def has_match(pattern: str, text: str) -> bool:
    return re.search(pattern, text, re.IGNORECASE) is not None


def read_text(path: Path) -> str:
    # utf-8-sig mirrors PowerShell's BOM-tolerant default reader.
    try:
        return path.read_text(encoding="utf-8-sig", errors="replace")
    except OSError:
        return ""


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest().upper()


def dict_get_ci(mapping: Any, key: str) -> tuple[Any, bool]:
    if not isinstance(mapping, dict):
        return None, False
    folded = key.casefold()
    for candidate, value in mapping.items():
        if isinstance(candidate, str) and candidate.casefold() == folded:
            return value, True
    return None, False


def text_value(value: Any) -> str:
    """Mirror PowerShell's [string] cast for JSON scalars."""
    if value is None:
        return ""
    if isinstance(value, bool):
        return "True" if value else "False"
    if isinstance(value, (int, float, str)):
        return str(value)
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def dotnet_type_name(value: Any) -> str:
    if isinstance(value, bool):
        return "System.Boolean"
    if isinstance(value, int):
        return "System.Int64"
    if isinstance(value, float):
        return "System.Double"
    if isinstance(value, str):
        return "System.String"
    if isinstance(value, list):
        return "System.Object[]"
    if isinstance(value, dict):
        return "System.Management.Automation.PSCustomObject"
    return type(value).__name__


def evidence_snippet(text: str) -> str:
    if not text or not text.strip():
        return ""
    if len(text) <= 240:
        return text
    return text[:237] + "..."


def version_at_least(actual: str, minimum: str) -> bool:
    actual_parts = [int(part) for part in re.findall(r"\d+", actual or "")]
    minimum_parts = [int(part) for part in re.findall(r"\d+", minimum or "")]
    if not actual_parts:
        return False
    for index in range(max(len(actual_parts), len(minimum_parts))):
        left = actual_parts[index] if index < len(actual_parts) else 0
        right = minimum_parts[index] if index < len(minimum_parts) else 0
        if left > right:
            return True
        if left < right:
            return False
    return True


def elf_machine(path: Path) -> Optional[int]:
    try:
        with path.open("rb") as handle:
            data = handle.read(20)
    except OSError:
        return None
    if len(data) < 20 or data[0:4] != b"\x7fELF":
        return None
    if data[5] == 2:
        return data[18] * 256 + data[19]
    return data[18] + data[19] * 256


class Audit:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.findings: List[dict] = []
        self._code_files: Optional[List[dict]] = None

    def add(self, severity: str, code: str, message: str, path: str = "",
            line: Optional[int] = None, evidence: str = "") -> None:
        self.findings.append({
            "severity": severity,
            "code": code,
            "message": message,
            "path": path,
            "line": line,
            "evidence": evidence,
        })

    def rel(self, path: Any) -> str:
        if path is None:
            return ""
        try:
            relative = os.path.relpath(str(path), str(self.root))
        except ValueError:
            relative = str(path)
        return relative.replace(os.sep, "/")

    def all_files(self) -> List[Path]:
        found = []
        for path in sorted(self.root.rglob("*")):
            try:
                if path.is_file():
                    found.append(path)
            except OSError:
                continue
        return found

    def project_code_files(self) -> List[dict]:
        if self._code_files is not None:
            return self._code_files

        files: List[dict] = []
        for path in self.all_files():
            try:
                size = path.stat().st_size
            except OSError:
                continue
            if size > MAX_CODE_FILE_BYTES:
                continue

            relative = self.rel(path)
            segments = relative.split("/")
            lowered = [segment.lower() for segment in segments]
            if lowered and lowered[0] in EXCLUDED_TOP_LEVEL:
                continue
            if any(segment in EXCLUDED_SEGMENTS for segment in lowered):
                continue

            extension = path.suffix.lower()
            is_lifecycle = relative.lower().startswith("cmd/")
            if extension not in CODE_EXTENSIONS and not is_lifecycle:
                continue

            text = read_text(path)
            lines = re.split(r"\r?\n", text)
            maximum = max((len(line) for line in lines), default=0)
            average = len(text) / max(1, len(lines))
            is_minified = len(text) > 20000 and (
                has_match(r"\.min$", path.stem)
                or len(lines) <= 5
                or average > 500
                or maximum > 5000
            )

            files.append({
                "path": path,
                "relative": relative,
                "text": text,
                "is_frontend": any(segment in FRONTEND_SEGMENTS for segment in lowered),
                "is_minified": is_minified,
            })

        self._code_files = files
        return files


def find_code_matches(files: List[dict], pattern: str, frontend_only: bool = False,
                      authored_only: bool = False) -> Iterator[dict]:
    regex = re.compile(pattern, re.IGNORECASE)
    for entry in files:
        if frontend_only and not entry["is_frontend"]:
            continue
        if authored_only and entry["is_minified"]:
            continue
        for index, line in enumerate(re.split(r"\r?\n", entry["text"]), start=1):
            if regex.search(line):
                yield {"path": entry["relative"], "line": index, "text": line.strip()}


def find_line_matches(path: Path, pattern: str) -> Iterator[dict]:
    regex = re.compile(pattern, re.IGNORECASE)
    for index, line in enumerate(read_text(path).splitlines(), start=1):
        if regex.search(line):
            yield {"line": index, "text": line.strip()}


def read_json_file(audit: Audit, path: Path, label: str) -> Any:
    if not path.is_file():
        return None
    try:
        return json.loads(read_text(path))
    except ValueError as exc:
        audit.add("High", "JSON_INVALID", f"{label} is not valid JSON.",
                  path=audit.rel(path), evidence=str(exc))
        return None


# This is deliberately a closed, reviewed control dialect, not a generic claim
# that arbitrary Python can be proved privilege-separated. Contracts are parsed
# independently from this engine, not learned from the package or its metadata.
# Per-function AST comparison accepts comments/formatting/diagnostic-only edits;
# changes to executable control flow remain unproved until explicitly reviewed.
_NATIVE_CONTROL_CONTRACT = r'''
class LifecycleError(RuntimeError):
    def __init__(self, message, code=1):
        super().__init__(message)
        self.code = code if isinstance(code, int) and 1 <= code <= 255 else 1

def command(args, timeout=60, input_text=None):
    try:
        result = subprocess.run(args, env=COMMAND_ENV, capture_output=True,
                                text=True, input=input_text, timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise LifecycleError('Command failed: ' + str(exc)) from exc
    if result.returncode:
        detail = (result.stderr or result.stdout or '').strip()[-3000:]
        raise LifecycleError('Command failed: ' + ' '.join(args[:3]) + '\n' + detail,
                             result.returncode)
    return result.stdout

def checked_path(raw, label):
    if not raw or any(ord(character) < 32 or ord(character) == 127 for character in raw):
        raise LifecycleError(label + ' is missing or contains control characters')
    supplied = Path(raw)
    if not supplied.is_absolute():
        raise LifecycleError(label + ' must be absolute')
    try:
        path = supplied.resolve(strict=True)
    except (OSError, RuntimeError) as exc:
        raise LifecycleError(label + ' must be an existing directory without symlink loops') from exc
    if not path.is_dir():
        raise LifecycleError(label + ' is not a directory')
    broad = {'/', '/var', '/var/apps', '/etc', '/usr', '/home', '/tmp', '/run', '/opt'}
    if str(path) in broad or re.fullmatch(r'/vol\d+', str(path)) or path.name != 'tripstar':
        raise LifecycleError(label + ' is not an application-specific tripstar directory')
    return path

def unit_string(value):
    text = str(value).replace('\\', '\\\\').replace('"', '\\"').replace('%', '%%')
    return '"' + text + '"'

def unit_path(value):
    return str(value).replace('%', '%%')

def env_string(value):
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'

def check_root_file(path, private=False):
    info = path.lstat()
    mode = stat.S_IMODE(info.st_mode)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or mode & 0o022:
        raise LifecycleError('File is not an immutable root-owned regular file: ' + str(path))
    if private and mode != 0o600:
        raise LifecycleError('Environment file must have mode 0600: ' + str(path))

def package_text(path, digest):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, 'rb') as handle:
        info = os.fstat(handle.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != 0
                or stat.S_IMODE(info.st_mode) & 0o002 or info.st_size > 131072):
            raise LifecycleError('Package asset is not a bounded root-owned regular file: ' + str(path))
        data = handle.read(131073)
    if len(data) > 131072:
        raise LifecycleError('Package asset exceeds its content bound: ' + str(path))
    if hashlib.sha256(data).hexdigest() != digest:
        raise LifecycleError('Package asset differs from its protected content pin: ' + str(path))
    return data.decode('utf-8')

def atomic_write(path, text, mode):
    if path.exists() or path.is_symlink():
        check_root_file(path)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8',
                                         dir=path.parent, delete=False) as handle:
            temporary = Path(handle.name)
            os.fchmod(handle.fileno(), mode)
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)

class Context:
    def __init__(self, app, var, etc, uid, gid):
        self.app, self.var, self.etc = app, var, etc
        self.uid, self.gid = uid, gid
        self.runtime = var / 'runtime'
        self.logs = var / 'logs'
        self.python = self.runtime / 'venv/bin/python'
        self.server = app / 'bin/run-server.py'
        self.control = CONTROL_ROOT
        self.unit_file = self.control / UNIT
        self.env_file = self.control / 'fnos-tripstar.env'

    @classmethod
    def from_environment(cls):
        if os.geteuid() != 0:
            raise LifecycleError('error')
        if os.environ.get('TRIM_APPNAME') != 'tripstar':
            raise LifecycleError('error')
        if os.environ.get('TRIM_USERNAME') != 'tripstar' or os.environ.get('TRIM_GROUPNAME') != 'tripstar':
            raise LifecycleError('error')
        app = checked_path(os.environ.get('TRIM_APPDEST'), 'TRIM_APPDEST')
        var = checked_path(os.environ.get('TRIM_PKGVAR'), 'TRIM_PKGVAR')
        etc = checked_path(os.environ.get('TRIM_PKGETC'), 'TRIM_PKGETC')
        if app != Path(__file__).resolve().parents[1]:
            raise LifecycleError('error')
        paths = (app, var, etc)
        if any(left == right or left.is_relative_to(right)
               for left in paths for right in paths if left is not right):
            raise LifecycleError('error')
        try:
            group_id = grp.getgrnam('tripstar').gr_gid
        except KeyError as exc:
            raise LifecycleError('error') from exc
        ids = []
        for variable, actual in (('TRIM_UID', command([ID, '-u', 'tripstar'], timeout=10).strip()),
                                 ('TRIM_GID', str(group_id))):
            supplied = os.environ.get(variable, '')
            if not re.fullmatch(r'[1-9][0-9]*', supplied) or supplied != actual:
                raise LifecycleError(variable + ' does not match the non-root tripstar identity')
            ids.append(int(supplied))
        if os.environ.get('TRIM_SERVICE_PORT', '17860') != '17860':
            raise LifecycleError('error')
        ctx = cls(app, var, etc, *ids)
        ctx.guard_control(absent_ok=True)
        return ctx

    def environment(self):
        return {'TRIM_APPDEST': str(self.app), 'TRIM_PKGVAR': str(self.var),
                'TRIM_SERVICE_PORT': '17860', 'HOME': str(self.runtime)}

    def rendered_unit(self):
        template = self.app / 'systemd' / (UNIT + '.in')
        text = package_text(template, TEMPLATE_SHA256)
        required = ('Type=exec', 'User=tripstar', 'Group=tripstar', 'Restart=always',
                    'KillMode=control-group', 'NoNewPrivileges=true',
                    'PrivateTmp=true', 'ProtectSystem=strict')
        lines = text.splitlines()
        critical = required + ('ExecStart=:@APP_PYTHON@ @SERVER_SCRIPT@',
                               'EnvironmentFile=@ENV_FILE@', 'WorkingDirectory=@APP_ROOT@',
                               'ReadWritePaths=@STATE_ROOT@')
        allowed = {'Description', 'After', 'Wants', 'Type', 'User', 'Group',
                   'EnvironmentFile', 'WorkingDirectory', 'ExecStart', 'Restart',
                   'RestartSec', 'KillMode', 'TimeoutStopSec', 'NoNewPrivileges',
                   'PrivateTmp', 'ProtectSystem', 'ProtectHome', 'ReadWritePaths',
                   'UMask', 'StandardOutput', 'StandardError'}
        keys = [line.split('=', 1)[0] for line in lines if '=' in line]
        if (any(lines.count(line) != 1 for line in critical) or
                len(keys) != len(set(keys)) or set(keys) - allowed):
            raise LifecycleError('error')
        replacements = {'@ENV_FILE@': unit_path(self.env_file),
                        '@APP_ROOT@': unit_path(self.app),
                        '@STATE_ROOT@': unit_string(self.var),
                        '@APP_PYTHON@': unit_string(self.python),
                        '@SERVER_SCRIPT@': unit_string(self.server)}
        for token, value in replacements.items():
            if text.count(token) != 1:
                raise LifecycleError('Unexpected service template token: ' + token)
            text = text.replace(token, value)
        if re.search(r'@[A-Z_]+@', text):
            raise LifecycleError('error')
        return text

    def guard_control(self, absent_ok=False):
        if self.control != CONTROL_ROOT:
            raise LifecycleError('error')
        parent = self.control.parent
        info = parent.lstat()
        if (parent.resolve() != parent or not stat.S_ISDIR(info.st_mode)
                or info.st_uid != 0 or stat.S_IMODE(info.st_mode) & 0o022):
            raise LifecycleError('error')
        try:
            info = self.control.lstat()
        except FileNotFoundError:
            if absent_ok:
                return False
            raise LifecycleError('error')
        if (not stat.S_ISDIR(info.st_mode) or info.st_uid != 0
                or stat.S_IMODE(info.st_mode) & 0o022):
            raise LifecycleError('error')
        return True

    def guard_link(self, absent_ok=False):
        if not UNIT_LINK.exists() and not UNIT_LINK.is_symlink():
            if absent_ok:
                return False
            raise LifecycleError('error')
        if not UNIT_LINK.is_symlink() or UNIT_LINK.resolve() != self.unit_file:
            raise LifecycleError('error')
        return True

    def properties(self, timeout=10):
        output = command([SYSTEMCTL, 'show', UNIT, '--no-pager',
                          '--property=LoadState,ActiveState,SubState,FragmentPath,User,Group,MainPID,DropInPaths'],
                         timeout=timeout)
        values = dict(line.split('=', 1) for line in output.splitlines() if '=' in line)
        if 'LoadState' not in values or 'ActiveState' not in values:
            raise LifecycleError('error')
        return values

    def verify_unit(self, values):
        if values.get('LoadState') == 'not-found':
            if self.guard_link(absent_ok=True):
                raise LifecycleError('error')
            return False
        self.guard_control()
        self.guard_link()
        fragment = values.get('FragmentPath', '')
        if not fragment or Path(fragment).resolve() != self.unit_file:
            raise LifecycleError('error')
        if values.get('User') != 'tripstar' or values.get('Group') != 'tripstar' or values.get('DropInPaths'):
            raise LifecycleError('error')
        check_root_file(self.unit_file)
        check_root_file(self.env_file, private=True)
        if self.unit_file.read_text(encoding='utf-8') != self.rendered_unit():
            raise LifecycleError('error')
        expected_env = ''.join(key + '=' + env_string(value) + '\n'
                               for key, value in self.environment().items())
        if self.env_file.read_text(encoding='utf-8') != expected_env:
            raise LifecycleError('error')
        return True

    def verify_pid(self, value):
        if not re.fullmatch(r'[1-9][0-9]*', value or ''):
            raise LifecycleError('error')
        proc = Path('/proc') / value
        try:
            status = (proc / 'status').read_text()
            fields = next(line.split()[1:] for line in status.splitlines() if line.startswith('Uid:'))
            argv = [part.decode() for part in (proc / 'cmdline').read_bytes().split(b'\0') if part]
        except (OSError, StopIteration, UnicodeDecodeError) as exc:
            raise LifecycleError('error') from exc
        if len(fields) != 4 or any(field != str(self.uid) for field in fields):
            raise LifecycleError('error')
        if not argv or argv[0] != str(self.python):
            raise LifecycleError('error')
        executable = command([READLINK, str(proc / 'exe')], timeout=10).strip()
        expected_executable = self.python.resolve()
        if Path(executable.removesuffix(' (deleted)')).resolve() != expected_executable:
            raise LifecycleError('error')
        direct = len(argv) >= 2 and argv[1] == str(self.server)
        gunicorn = (argv[1:3] == ['-m', 'gunicorn'] and 'backend.app.api.main:app' in argv)
        if gunicorn:
            try:
                gunicorn = (argv[argv.index('--chdir') + 1] == str(self.app) and
                            argv[argv.index('--bind') + 1] == '0.0.0.0:17860')
            except (ValueError, IndexError):
                gunicorn = False
        if not direct and not gunicorn:
            raise LifecycleError('error')

    def port_free(self):
        for family, host in ((socket.AF_INET, '0.0.0.0'), (socket.AF_INET6, '::')):
            try:
                with socket.socket(family, socket.SOCK_STREAM) as listener:
                    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                    if family == socket.AF_INET6:
                        listener.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
                    listener.bind((host, 17860))
            except OSError as exc:
                if exc.errno == errno.EADDRINUSE:
                    return False
                if family == socket.AF_INET6 and exc.errno in (errno.EAFNOSUPPORT, errno.EADDRNOTAVAIL):
                    continue
                raise LifecycleError('Service port inspection failed: ' + str(exc)) from exc
        return True

    def require_free_port(self):
        if not self.port_free():
            raise LifecycleError('error')

    def healthy(self, timeout=2):
        try:
            with urlopen('http://127.0.0.1:17860/health', timeout=timeout) as response:
                body = response.read(16385)
                return len(body) <= 16384 and json.loads(body).get('status') == 'healthy'
        except (OSError, URLError, ValueError, AttributeError):
            return False

    def start(self):
        values = self.properties()
        if not self.verify_unit(values):
            raise LifecycleError('error')
        if values['ActiveState'] == 'active':
            self.verify_pid(values.get('MainPID'))
            if self.healthy():
                return 0
            raise LifecycleError('error')
        self.require_free_port()
        deadline = time.monotonic() + 60
        command([SYSTEMCTL, 'start', UNIT], timeout=60)
        while time.monotonic() < deadline:
            remaining = max(0.1, deadline - time.monotonic())
            values = self.properties(timeout=min(5, remaining))
            self.verify_unit(values)
            if values['ActiveState'] in ('inactive', 'failed', 'deactivating'):
                raise LifecycleError('error')
            if values['ActiveState'] == 'active':
                self.verify_pid(values.get('MainPID'))
                remaining = deadline - time.monotonic()
                if remaining > 0 and self.healthy(timeout=min(2, remaining)):
                    return 0
            remaining = deadline - time.monotonic()
            if remaining > 0:
                time.sleep(min(1, remaining))
        raise LifecycleError('error')

    def stop(self):
        values = self.properties()
        if not self.verify_unit(values):
            self.require_free_port()
            return 0
        if values.get('MainPID', '0') != '0':
            self.verify_pid(values.get('MainPID'))
        command([SYSTEMCTL, 'stop', UNIT])
        values = self.properties()
        self.verify_unit(values)
        if values.get('MainPID', '0') != '0' or values['ActiveState'] not in ('inactive', 'failed'):
            raise LifecycleError('error')
        self.require_free_port()
        return 0

    def status(self):
        values = self.properties()
        if not self.verify_unit(values) or values['ActiveState'] in ('inactive', 'failed'):
            return 3
        if values['ActiveState'] == 'activating':
            return 3
        if values['ActiveState'] != 'active':
            raise LifecycleError('error')
        self.verify_pid(values.get('MainPID'))
        return 0 if self.healthy() else 3

    def prepare(self):
        self.guard_control(absent_ok=True)
        self.control.mkdir(mode=0o700, exist_ok=True)
        self.guard_control()
        self.guard_link(absent_ok=True)
        for directory in (self.runtime, self.logs):
            if directory.is_symlink():
                raise LifecycleError('Mutable application directory is a symlink: ' + str(directory))
            directory.mkdir(exist_ok=True, mode=0o700)
            descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                if not stat.S_ISDIR(os.fstat(descriptor).st_mode):
                    raise LifecycleError('error')
                os.fchown(descriptor, self.uid, self.gid)
                os.fchmod(descriptor, 0o700)
            finally:
                os.close(descriptor)
        setup_file = self.app / 'bin/setup-runtime.py'
        setup_source = package_text(setup_file, SETUP_SHA256)
        setup_output = command([RUNUSER, '-u', 'tripstar', '-g', 'tripstar', '--', '/usr/bin/env', '-i',
                                *[key + '=' + value for key, value in self.environment().items()],
                                'PATH=/var/apps/nodejs_v22/target/bin:/usr/bin:/bin',
                                PYTHON, '-I', '-B', '-c', SETUP_RUNNER, str(setup_file), SETUP_SHA256],
                               timeout=600, input_text=setup_source)
        if setup_output:
            try:
                print(setup_output, end='')
            except OSError:
                pass
        text = self.rendered_unit()
        env = ''.join(key + '=' + env_string(value) + '\n'
                      for key, value in self.environment().items())
        atomic_write(self.unit_file, text, 0o644)
        atomic_write(self.env_file, env, 0o600)
        if not self.guard_link(absent_ok=True):
            os.symlink(self.unit_file, UNIT_LINK)
        command([SYSTEMCTL, 'daemon-reload'])
        return 0

    def uninstall(self):
        self.stop()
        if self.guard_link(absent_ok=True):
            UNIT_LINK.unlink()
            command([SYSTEMCTL, 'daemon-reload'])
        return 0

    def dispatch(self, action):
        if action == 'install_init':
            return 0
        if action == 'install_callback':
            return self.prepare()
        if action == 'upgrade_init':
            return self.uninstall()
        if action == 'upgrade_callback':
            self.stop()
            return self.prepare()
        if action == 'uninstall_init':
            return self.uninstall()
        if action == 'uninstall_callback':
            return 0
        if action in ('start', 'stop', 'status'):
            return getattr(self, action)()
        raise LifecycleError('Unsupported lifecycle action: ' + action)

def open_root_log(target):
    path = Path(target)
    if not path.is_absolute():
        raise PermissionError('error')
    parent = path.parent.resolve(strict=True)
    roots = [Path('/tmp'), Path('/run')]
    temporary = os.environ.get('TRIM_PKGTMP')
    if temporary:
        try:
            roots.append(checked_path(temporary, 'TRIM_PKGTMP'))
        except LifecycleError:
            pass
    if not any(parent == root or parent.is_relative_to(root) for root in roots):
        raise PermissionError('error')
    parent_fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    descriptor = None
    try:
        info = os.fstat(parent_fd)
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or stat.S_IMODE(info.st_mode) & 0o022:
            raise PermissionError('error')
        flags = os.O_WRONLY | os.O_NOFOLLOW | os.O_NONBLOCK
        try:
            descriptor = os.open(path.name, flags, dir_fd=parent_fd)
        except FileNotFoundError:
            descriptor = os.open(path.name, flags | os.O_CREAT | os.O_EXCL,
                                 0o600, dir_fd=parent_fd)
        info = os.fstat(descriptor)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or
                stat.S_IMODE(info.st_mode) & 0o022):
            raise PermissionError('error')
        os.ftruncate(descriptor, 0)
        result, descriptor = descriptor, None
        return result
    finally:
        if descriptor is not None:
            os.close(descriptor)
        os.close(parent_fd)

def report_failure(message):
    try:
        print(message, file=sys.stderr)
    except OSError:
        pass
    target = os.environ.get('TRIM_TEMP_LOGFILE', '')
    if (os.geteuid() != 0 or not target or
            any(ord(character) < 32 or ord(character) == 127 for character in target)):
        return
    try:
        descriptor = open_root_log(target)
        with os.fdopen(descriptor, 'w') as handle:
            handle.write(message + '\n')
    except (OSError, ValueError, RuntimeError):
        pass

def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    try:
        if len(argv) != 1:
            raise LifecycleError('error')
        return Context.from_environment().dispatch(argv[0])
    except LifecycleError as exc:
        report_failure(str(exc))
        return 1 if argv == ['status'] else exc.code
    except (OSError, ValueError) as exc:
        report_failure('TripStar lifecycle failed: ' + str(exc))
        return 1
'''

_NATIVE_METADATA = {
    "schema": "tripstar-systemd-nonroot-v1",
    "controller": "app/bin/lifecycle.py",
    "server": "app/bin/run-server.py",
    "unit_template": "app/systemd/fnos-tripstar.service.in",
    "setup": "app/bin/setup-runtime.py",
}
_NATIVE_GLOBALS = {
    "UNIT": "'fnos-tripstar.service'",
    "UNIT_LINK": "Path('/etc/systemd/system') / UNIT",
    "CONTROL_ROOT": "Path('/etc/fnos-tripstar')",
    "SYSTEMCTL": "'/usr/bin/systemctl'",
    "RUNUSER": "'/usr/sbin/runuser'",
    "ID": "'/usr/bin/id'",
    "READLINK": "'/usr/bin/readlink'",
    "PYTHON": "'/var/apps/python312/target/bin/python3.12'",
    "SETUP_SHA256": "'a126b0d41855a1fc07560c150d9d5a8207187999f8d172aeb58bf72ff643abb0'",
    "TEMPLATE_SHA256": "'c5d2ea36996b323d43606eace7d947d1e4a924f3c2270ed273bebdee2c668435'",
    "SETUP_RUNNER": repr("import sys\n"
                         "path, digest = sys.argv[1:3]\n"
                         "source = sys.stdin.read(131073)\n"
                         "if len(source) > 131072: raise RuntimeError('Setup source exceeds its bound')\n"
                         "sys.argv = [path]\n"
                         "exec(compile(source, path, 'exec'), {'__name__': '__main__', '__file__': path, "
                         "'__verified_source_sha256__': digest})\n"),
    "COMMAND_ENV": "{'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'LANG': 'C.UTF-8'}",
}
_NATIVE_IMPORTS = (
    "import errno", "import grp", "import hashlib", "import json", "import os", "from pathlib import Path",
    "import re", "import socket", "import stat", "import subprocess", "import sys",
    "import tempfile", "import time", "from urllib.error import URLError",
    "from urllib.request import urlopen",
)
_NATIVE_MAIN_SHELL = r'''#!/bin/sh
set -eu
phase=${1:-}
case "$phase" in
install_init|uninstall_callback)
exit 0
;;
start|stop|status|install_callback|upgrade_init|upgrade_callback|uninstall_init)
;;
*)
printf '%s\n' "Unsupported lifecycle action: ${phase:-empty}" >&2
exit 1
;;
esac
: "${TRIM_APPDEST:?missing TRIM_APPDEST}"
PYTHON=/var/apps/python312/target/bin/python3.12
if [ ! -x "$PYTHON" ]; then
message='Python 3.12 运行文件缺失。请在飞牛应用中心安装或修复 Python 3.12，再重新安装 TripStar；仅有依赖应用登记还不足以运行。'
printf '%s\n' "$message" >&2
exit 1
fi
exec "$PYTHON" -I -B - "$phase" <<'PY'
import hashlib
import os
from pathlib import Path
import stat
import sys

expected = '@CONTROLLER_SHA256@'
previous = ('3be2bf491c90b0d175a87d8eac330d709970a590e20f85fc2a6c28305ae75ea2',
            '9e2e740c9fb53941b6fbb3374f7f35cdc5aeb9a625a40e4c49df9455e96fa2b0')
controller = Path(os.environ['TRIM_APPDEST']) / 'bin/lifecycle.py'
descriptor = os.open(controller, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
with os.fdopen(descriptor, 'rb') as handle:
    info = os.fstat(handle.fileno())
    if (not stat.S_ISREG(info.st_mode) or info.st_uid != 0
            or stat.S_IMODE(info.st_mode) & 0o002 or info.st_size > 131072):
        raise RuntimeError('Lifecycle source is not a bounded regular file')
    source = handle.read(131073)
digest = hashlib.sha256(source).hexdigest()
prior_upgrade = sys.argv[1] == 'upgrade_init' and digest in previous
if len(source) > 131072 or (digest != expected and not prior_upgrade):
    raise RuntimeError('Lifecycle source differs from its protected content pin')
sys.argv = [str(controller), sys.argv[1]]
exec(compile(source, str(controller), 'exec'), {'__name__': '__main__', '__file__': str(controller)})
PY
'''


class NativeProofError(ValueError):
    pass


class _NativeDiagnosticNormalizer(ast.NodeTransformer):
    def visit_FunctionDef(self, node: ast.FunctionDef) -> ast.AST:
        self.generic_visit(node)
        if node.body and isinstance(node.body[0], ast.Expr):
            value = node.body[0].value
            if isinstance(value, ast.Constant) and isinstance(value.value, str):
                node.body.pop(0)
        return node

    def visit_Raise(self, node: ast.Raise) -> ast.AST:
        self.generic_visit(node)
        # Only a literal diagnostic is inert; never erase f-strings, calls, or
        # other expressions that execute before raising an exception.
        if (isinstance(node.exc, ast.Call) and node.exc.args
                and isinstance(node.exc.args[0], ast.Constant)
                and isinstance(node.exc.args[0].value, str)):
            node.exc.args[0] = ast.Constant(value="<diagnostic>")
        return node


def _native_ast_key(node: ast.AST) -> str:
    normalized = _NativeDiagnosticNormalizer().visit(copy.deepcopy(node))
    return ast.dump(normalized, include_attributes=False)


def _native_json(text: str) -> Any:
    def unique(pairs: list) -> dict:
        result = {}
        for key, value in pairs:
            if key in result:
                raise NativeProofError("duplicate JSON key: " + key)
            result[key] = value
        return result
    return json.loads(text, object_pairs_hook=unique)


def _native_file(root: Path, relative: str, *, app: bool = True) -> Path:
    if (not isinstance(relative, str) or not relative or "\\" in relative
            or Path(relative).is_absolute() or any(part in {"", ".", ".."}
                                                 for part in relative.split("/"))
            or (app and not relative.startswith("app/"))):
        raise NativeProofError("invalid evidence path: " + str(relative))
    current = root
    for part in relative.split("/"):
        current = current / part
        if current.is_symlink():
            raise NativeProofError("symlinked evidence path: " + relative)
    if (not current.resolve(strict=True).is_relative_to(root.resolve())
            or not current.is_file() or current.stat().st_size > MAX_LIFECYCLE_FILE_BYTES):
        raise NativeProofError("evidence is not a bounded package file: " + relative)
    if current.stat().st_mode & 0o022:
        raise NativeProofError("evidence is group/world-writable: " + relative)
    return current


def _native_shell_lines(text: str) -> list[str]:
    return [line.strip() for line in text.splitlines()
            if line.strip() and (not line.lstrip().startswith("#") or line.startswith("#!"))]


def _native_main(text: str, controller_source: bytes) -> None:
    marker = 'exec "$PYTHON" -I -B - "$phase" <<\'PY\'\n'
    if text.count(marker) != 1:
        raise NativeProofError("cmd/main is not the protected isolated memory loader")
    shell, loader = text.split(marker, 1)
    model_shell, model_loader = _NATIVE_MAIN_SHELL.split(marker, 1)
    if (_native_shell_lines(shell) != _native_shell_lines(model_shell)
            or not loader.endswith("PY\n")):
        raise NativeProofError("cmd/main shell or loader boundary changed")
    loader = loader[:-3]
    pin_pattern = r"(?m)^expected = '([0-9a-f]{64})'$"
    pins = re.findall(pin_pattern, loader)
    if (len(controller_source) > 131072 or len(pins) != 1
            or pins[0] != hashlib.sha256(controller_source).hexdigest()):
        raise NativeProofError("protected lifecycle pin does not bind the bounded controller bytes")
    normalized = re.sub(pin_pattern, "expected = '@CONTROLLER_SHA256@'", loader, count=1)
    if ast.dump(ast.parse(normalized), include_attributes=False) != ast.dump(
            ast.parse(model_loader[:-3]), include_attributes=False):
        raise NativeProofError("protected memory loader differs from its closed AST contract")


def _native_definitions(tree: ast.Module) -> dict[str, ast.AST]:
    result = {}
    for node in tree.body:
        if isinstance(node, ast.FunctionDef):
            key = node.name
            if key in result:
                raise NativeProofError("duplicate controller function: " + key)
            result[key] = node
        elif isinstance(node, ast.ClassDef):
            if node.keywords:
                raise NativeProofError("controller metaclass is not supported")
            header = copy.deepcopy(node)
            header.body = []
            if node.name in result:
                raise NativeProofError("duplicate controller class: " + node.name)
            result[node.name] = header
            for method in node.body:
                if not isinstance(method, ast.FunctionDef):
                    raise NativeProofError("unsupported controller class statement: " + node.name)
                key = node.name + "." + method.name
                if key in result:
                    raise NativeProofError("duplicate controller method: " + key)
                result[key] = method
    return result


def _native_controller(tree: ast.Module) -> None:
    actual = _native_definitions(tree)
    expected = _native_definitions(ast.parse(_NATIVE_CONTROL_CONTRACT))
    if actual.keys() != expected.keys():
        raise NativeProofError("controller definitions differ from the closed control graph")
    for name, model in expected.items():
        if _native_ast_key(actual[name]) != _native_ast_key(model):
            raise NativeProofError("unproved controller control flow: " + name)
    imports = set()
    constants = {}
    footer = ast.parse("if __name__ == '__main__':\n    raise SystemExit(main())").body[0]
    footers = []
    for index, node in enumerate(tree.body):
        if isinstance(node, (ast.FunctionDef, ast.ClassDef)):
            continue
        if (index == 0 and isinstance(node, ast.Expr)
                and isinstance(node.value, ast.Constant) and isinstance(node.value.value, str)):
            continue
        if isinstance(node, (ast.Import, ast.ImportFrom)):
            key = ast.dump(node, include_attributes=False)
            if key in imports:
                raise NativeProofError("duplicate controller import")
            imports.add(key)
        elif (isinstance(node, ast.Assign) and len(node.targets) == 1
                and isinstance(node.targets[0], ast.Name)):
            name = node.targets[0].id
            if name not in _NATIVE_GLOBALS or name in constants:
                raise NativeProofError("unproved controller global: " + name)
            constants[name] = ast.dump(node.value, include_attributes=False)
        elif isinstance(node, ast.If) and _native_ast_key(node) == _native_ast_key(footer):
            footers.append(index)
        else:
            raise NativeProofError("controller has an unproved top-level effect")
    approved_imports = {ast.dump(ast.parse(text).body[0], include_attributes=False)
                        for text in _NATIVE_IMPORTS}
    if imports != approved_imports:
        raise NativeProofError("controller imports are outside the closed standard-library set")
    approved_globals = {name: ast.dump(ast.parse(text, mode="eval").body, include_attributes=False)
                        for name, text in _NATIVE_GLOBALS.items()}
    if constants != approved_globals:
        raise NativeProofError("controller executable/unit/environment binding changed")
    if footers != [len(tree.body) - 1]:
        raise NativeProofError("controller must have one final guarded main entry")


def _native_unit(text: str) -> None:
    approved = {
        "Unit": {"Description": "TripStar fnOS native service", "After": "network-online.target",
                 "Wants": "network-online.target"},
        "Service": {
            "Type": "exec", "User": "tripstar", "Group": "tripstar",
            "EnvironmentFile": "@ENV_FILE@", "WorkingDirectory": "@APP_ROOT@",
            "ExecStart": ":@APP_PYTHON@ @SERVER_SCRIPT@", "Restart": "always",
            "RestartSec": "3", "KillMode": "control-group", "TimeoutStopSec": "30",
            "NoNewPrivileges": "true", "PrivateTmp": "true", "ProtectSystem": "strict",
            "ProtectHome": "true", "ReadWritePaths": "@STATE_ROOT@", "UMask": "0077",
            "StandardOutput": "journal", "StandardError": "journal",
        },
    }
    sections = {}
    current = None
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith(("#", ";")):
            continue
        if line.startswith("[") and line.endswith("]"):
            current = line[1:-1]
            if current not in approved or current in sections:
                raise NativeProofError("unknown or duplicate systemd section")
            sections[current] = {}
        elif current is None or "=" not in line:
            raise NativeProofError("unproved systemd syntax")
        else:
            key, value = line.split("=", 1)
            if key in sections[current]:
                raise NativeProofError("duplicate systemd directive: " + key)
            sections[current][key] = value
    if sections != approved:
        raise NativeProofError("systemd directives differ from the static non-root contract")


def _native_server(tree: ast.Module) -> None:
    imports = {ast.dump(ast.parse(text).body[0], include_attributes=False) for text in (
        "import os", "from pathlib import Path", "import subprocess", "import sys")}
    seen = set()
    functions = []
    footer = ast.parse("if __name__ == '__main__':\n    main()").body[0]
    footers = []
    for index, node in enumerate(tree.body):
        if (index == 0 and isinstance(node, ast.Expr)
                and isinstance(node.value, ast.Constant) and isinstance(node.value.value, str)):
            continue
        if isinstance(node, (ast.Import, ast.ImportFrom)):
            key = ast.dump(node, include_attributes=False)
            if key not in imports or key in seen:
                raise NativeProofError("server has an unproved top-level import")
            seen.add(key)
        elif isinstance(node, ast.FunctionDef) and node.name == "main":
            functions.append(node)
        elif isinstance(node, ast.If) and _native_ast_key(node) == _native_ast_key(footer):
            footers.append(index)
        else:
            raise NativeProofError("server has an unproved top-level effect")
    if seen != imports or len(functions) != 1 or footers != [len(tree.body) - 1]:
        raise NativeProofError("server must have only standard imports and a guarded main entry")
    function = functions[0]
    if (function.decorator_list or function.args.defaults or function.args.kw_defaults
            or function.args.posonlyargs or function.args.args or function.args.kwonlyargs
            or function.args.vararg or function.args.kwarg or function.returns):
        raise NativeProofError("server main definition can execute before its root guard")
    expected = ast.parse("if os.geteuid() == 0:\n    raise RuntimeError('error')").body[0]
    if not function.body or _native_ast_key(function.body[0]) != _native_ast_key(expected):
        raise NativeProofError("server main must immediately raise on effective UID zero")


def prove_native_nonroot_runtime(root: Path, privilege: Any, manifest: dict) -> tuple[bool, str]:
    """Prove only the reviewed TripStar root-lifecycle/non-root-runtime dialect.

    Evidence metadata merely locates source. It never asserts trust or carries a
    hash/waiver. Only the closed, pinned memory loaders are proved; any missing
    file, unbound execution, or unknown AST stays root.
    """
    evidence_path = root / "audit-native-runtime.json"
    if not evidence_path.exists():
        return False, "no explicit native-runtime source evidence"
    try:
        metadata_file = _native_file(root, "audit-native-runtime.json", app=False)
        metadata = _native_json(metadata_file.read_text(encoding="utf-8"))
        if metadata != _NATIVE_METADATA:
            raise NativeProofError("unsupported or incomplete native-runtime evidence schema")
        exact_privilege = _native_json(_native_file(root, "config/privilege", app=False).read_text())
        approved_privilege = {"defaults": {"run-as": "root"},
                              "username": "tripstar", "groupname": "tripstar"}
        if privilege != exact_privilege or exact_privilege != approved_privilege:
            raise NativeProofError("fixed non-root package user/group binding is missing")
        if manifest.get("appname") != "tripstar" or manifest.get("service_port") != "17860":
            raise NativeProofError("manifest differs from the closed native control identity")
        paths = {name: _native_file(root, relative)
                 for name, relative in metadata.items() if name != "schema"}
        templates = [path for path in (root / "app").rglob("*")
                     if path.name.endswith((".service", ".service.in"))]
        if templates != [paths["unit_template"]]:
            raise NativeProofError("package must contain exactly its referenced systemd template")
        _native_unit(paths["unit_template"].read_text(encoding="utf-8"))
        main_file = _native_file(root, "cmd/main", app=False)
        if not main_file.stat().st_mode & 0o111:
            raise NativeProofError("lifecycle main is not executable")
        controller_source = paths["controller"].read_bytes()
        _native_main(main_file.read_text(), controller_source)
        phases = ("install_init", "install_callback", "upgrade_init", "upgrade_callback",
                  "uninstall_init", "uninstall_callback")
        expected_cmd = {"main", *phases}
        if {path.name for path in (root / "cmd").iterdir()} != expected_cmd:
            raise NativeProofError("package has unknown lifecycle command files")
        for phase in phases:
            path = _native_file(root, "cmd/" + phase, app=False)
            if not path.stat().st_mode & 0o111:
                raise NativeProofError("lifecycle phase is not executable: " + phase)
            expected = '#!/bin/sh\nexec "$(/usr/bin/dirname "$0")/main" ' + phase
            if _native_shell_lines(path.read_text()) != _native_shell_lines(expected):
                raise NativeProofError("lifecycle phase is not a fixed main dispatcher: " + phase)
        _native_controller(ast.parse(controller_source.decode("utf-8")))
        for name, asset in (("SETUP_SHA256", "setup"), ("TEMPLATE_SHA256", "unit_template")):
            source = paths[asset].read_bytes()
            if (len(source) > 131072 or hashlib.sha256(source).hexdigest()
                    != ast.literal_eval(_NATIVE_GLOBALS[name])):
                raise NativeProofError("protected package pin does not bind " + asset)
        _native_server(ast.parse(paths["server"].read_text(encoding="utf-8")))
        # The approved controller binds template/server/setup names independently
        # of metadata, renders only five quoted path tokens, writes that exact
        # unit/env, rejects foreign DropIns/PIDs, and starts only its fixed unit.
        return True, "verified root preparation and static non-root systemd execution chain"
    except (OSError, UnicodeError, ValueError, SyntaxError, RecursionError) as exc:
        return False, str(exc)


def audit_project(root: Path) -> dict:
    audit = Audit(root)
    all_files = audit.all_files()

    # ---------------------------------------------------------------- manifest
    manifest: dict[str, str] = {}
    manifest_lines: dict[str, int] = {}
    manifest_path = root / "manifest"
    if not manifest_path.is_file():
        audit.add("High", "MANIFEST_MISSING", "Package root has no manifest file.")
    else:
        for index, line in enumerate(read_text(manifest_path).splitlines(), start=1):
            matched = re.match(r"^\s*([A-Za-z0-9_]+)\s*=\s*(.*?)\s*$", line)
            if matched:
                key = matched.group(1).casefold()
                manifest[key] = matched.group(2)
                manifest_lines[key] = index

        for field in ("appname", "version", "display_name", "platform", "desc", "source"):
            if not manifest.get(field, "").strip():
                audit.add("High", "MANIFEST_REQUIRED_FIELD",
                          f"Manifest field '{field}' is missing or empty.",
                          path="manifest")

        declared_platform = manifest.get("platform")
        if declared_platform is not None and declared_platform.strip().casefold() not in {"x86", "arm", "all"}:
            audit.add("High", "MANIFEST_PLATFORM_INVALID",
                      "Manifest platform must be x86, arm, or all.",
                      path="manifest", line=manifest_lines.get("platform"),
                      evidence=declared_platform)

        for field in ("checksum", "fpk_version", "beta"):
            if field in manifest:
                audit.add("Info", "COMMUNITY_MANIFEST_FIELD",
                          f"Preserve community metadata '{field}' until its consumer is identified.",
                          path="manifest", line=manifest_lines.get(field),
                          evidence=manifest[field])

    # ------------------------------------------------------- privilege/resource
    privilege_path = root / "config" / "privilege"
    resource_path = root / "config" / "resource"
    privilege = read_json_file(audit, privilege_path, "config/privilege")
    resource = read_json_file(audit, resource_path, "config/resource")

    run_as = ""
    defaults, defaults_found = dict_get_ci(privilege, "defaults")
    if defaults_found:
        run_as_value, run_as_found = dict_get_ci(defaults, "run-as")
        if run_as_found:
            run_as = text_value(run_as_value)
    if run_as.casefold() == "root":
        separated, reason = prove_native_nonroot_runtime(root, privilege, manifest)
        if not separated:
            audit.add("Medium", "ROOT_RUNTIME",
                      "Long-running application code is configured to run as root; require evidence "
                      "that package identity or groups are insufficient.",
                      path=audit.rel(privilege_path), evidence="Native runtime proof: " + reason)

    # ------------------------------------------------------------- UI entries
    desktop_ui_dir = manifest["desktop_uidir"] if "desktop_uidir" in manifest else "ui"
    ui_candidates = [candidate for candidate in (
        root / "app" / desktop_ui_dir / "config",
        root / desktop_ui_dir / "config",
    ) if candidate.is_file()]

    if len(ui_candidates) > 1:
        hashes = {sha256_file(candidate) for candidate in ui_candidates}
        audit.add("Info", "DUPLICATE_UI_SOURCE",
                  "UI config exists in both staged and application locations; verify which "
                  "copy enters the final FPK.",
                  path=audit.rel(ui_candidates[0]),
                  evidence="copies currently match" if len(hashes) == 1 else "copies differ")

    ui_path = ui_candidates[0] if ui_candidates else None
    ui = read_json_file(audit, ui_path, "desktop UI config") if ui_path else None

    entries: List[tuple[str, Any]] = []
    url_value, url_found = dict_get_ci(ui, ".url")
    if url_found and isinstance(url_value, dict):
        entries = list(url_value.items())

    if "desktop_applaunchname" in manifest:
        launch_name = manifest["desktop_applaunchname"]
        if not entries:
            audit.add("High", "ENTRY_CONFIG_MISSING",
                      "Manifest declares desktop_applaunchname but no readable .url entry was found.",
                      path="manifest", line=manifest_lines.get("desktop_applaunchname"))
        elif not any(name.casefold() == launch_name.casefold() for name, _ in entries):
            audit.add("High", "ENTRY_ID_MISMATCH",
                      "desktop_applaunchname does not match an entry ID in the UI config.",
                      path="manifest", line=manifest_lines.get("desktop_applaunchname"),
                      evidence="manifest={0}; entries={1}".format(
                          launch_name, ",".join(name for name, _ in entries)))

    all_users_entries = []
    for name, value in entries:
        flag, flag_found = dict_get_ci(value, "allUsers")
        if flag_found and bool(flag):
            all_users_entries.append(name)
    if run_as.casefold() == "root" and all_users_entries:
        audit.add("High", "ROOT_ALL_USERS",
                  "A root-running package exposes a desktop entry to all users; review "
                  "authentication, authorization, CSRF/origin controls, bind address, and "
                  "privileged capabilities together.",
                  path=audit.rel(ui_path), evidence=",".join(all_users_entries))

    # Device-verified entry field contracts (see references/platform-contract.md):
    # - port must be a JSON string; numeric ports broke client URL assembly.
    # - url is a request path assembled with protocol+port; a full link in it
    #   makes the client fall back to the gateway path and refuse connections.
    for name, value in entries:
        if not isinstance(value, dict):
            continue
        entry_type, type_found = dict_get_ci(value, "type")
        if type_found and entry_type not in ("iframe", "url"):
            audit.add("Medium", "ENTRY_BAD_TYPE",
                      "Entry type must be 'iframe' (desktop window) or 'url' "
                      "(external browser tab).",
                      path=audit.rel(ui_path), evidence="{0}: {1!r}".format(name, entry_type))
        port_value, port_found = dict_get_ci(value, "port")
        if port_found and not isinstance(port_value, str):
            audit.add("Medium", "ENTRY_PORT_NOT_STRING",
                      "Entry port must be a quoted string; a numeric JSON port broke "
                      "client-side URL assembly on real devices.",
                      path=audit.rel(ui_path), evidence="{0}: port={1!r}".format(name, port_value))
        url_field, url_field_found = dict_get_ci(value, "url")
        if url_field_found and isinstance(url_field, str) and "://" in url_field:
            audit.add("Medium", "ENTRY_URL_FULL_LINK",
                      "Entry 'url' field is a request path (e.g. '/'); put the scheme "
                      "in 'protocol' and the port in 'port', not a full link here.",
                      path=audit.rel(ui_path), evidence="{0}: url={1}".format(name, url_field))

    # --------------------------------------------------------------- Open API
    source_files = audit.project_code_files()
    authored_text = "\n".join(
        entry["text"] for entry in source_files if not entry["is_minified"])

    api_scopes: List[str] = []
    scope_value, scope_found = dict_get_ci(resource, "api-scope")
    if scope_found:
        if not isinstance(scope_value, list):
            scope_type = "<null>" if scope_value is None else dotnet_type_name(scope_value)
            audit.add("High", "OPENAPI_SCOPE_INVALID",
                      "config/resource api-scope must be a JSON array of non-empty strings.",
                      path=audit.rel(resource_path), evidence=f"type={scope_type}")
        else:
            for scope in scope_value:
                if not isinstance(scope, str) or not scope.strip():
                    audit.add("High", "OPENAPI_SCOPE_INVALID",
                              "config/resource api-scope contains a value that is not a "
                              "non-empty string.",
                              path=audit.rel(resource_path),
                              evidence=json.dumps(scope, ensure_ascii=False,
                                                  separators=(",", ":")))
                    continue
                api_scopes.append(scope)

    sdk_match = next(iter(find_code_matches(source_files, SDK_PATTERN)), None)
    if sdk_match is not None and manifest.get("micro_app", "").casefold() != "true":
        audit.add("High", "OPENAPI_MICRO_APP_REQUIRED",
                  "Frontend code uses @trimjs/web-app, but manifest does not declare micro_app=true.",
                  path=sdk_match["path"], line=sdk_match["line"],
                  evidence=evidence_snippet(sdk_match["text"]))

    folded_scopes = {scope.casefold() for scope in api_scopes}
    open_api_usage_matches = []
    for scope, pattern in SCOPE_USAGE_RULES:
        usage_match = next(iter(find_code_matches(source_files, pattern, authored_only=True)), None)
        if usage_match is None:
            continue
        open_api_usage_matches.append(usage_match)
        if scope.casefold() not in folded_scopes:
            audit.add("High", "OPENAPI_SCOPE_MISSING",
                      "Code uses an fnOS Open API capability without declaring its required api-scope.",
                      path=usage_match["path"], line=usage_match["line"],
                      evidence="required={0}; marker={1}".format(
                          scope, evidence_snippet(usage_match["text"])))

    backend_match = next(iter(find_code_matches(source_files, BACKEND_API_PATTERN)), None)
    uses_open_api = (sdk_match is not None or backend_match is not None
                     or bool(open_api_usage_matches) or bool(api_scopes))
    if uses_open_api:
        declared_minimum = manifest.get("os_min_version", "")
        if not declared_minimum.strip() or not version_at_least(declared_minimum, OPEN_API_MINIMUM_VERSION):
            audit.add("Medium", "OPENAPI_VERSION_GATE",
                      "The bundled official Open API contract requires fnOS 1.2.0401 or newer; "
                      "raise os_min_version or document and test an explicit older-host fallback.",
                      path="manifest", line=manifest_lines.get("os_min_version"),
                      evidence="declared={0}; required={1}".format(
                          declared_minimum if declared_minimum.strip() else "<missing>",
                          OPEN_API_MINIMUM_VERSION))

    for match in find_code_matches(source_files, BACKEND_API_PATTERN, frontend_only=True):
        audit.add("High", "OPENAPI_FRONTEND_BACKEND_API",
                  "Frontend code contains the backend Open API endpoint, Unix Socket, or "
                  "TRIM_API_TOKEN; backend Open APIs must remain server-side.",
                  path=match["path"], line=match["line"],
                  evidence=evidence_snippet(match["text"]))

    for match in find_code_matches(source_files, TOKEN_LOGGING_PATTERN):
        audit.add("High", "OPENAPI_TOKEN_EXPOSURE",
                  "Code may write TRIM_API_TOKEN to a log or console; the token must remain secret.",
                  path=match["path"], line=match["line"],
                  evidence=evidence_snippet(match["text"]))
    for match in find_code_matches(source_files, TOKEN_PERSISTENCE_PATTERN):
        audit.add("High", "OPENAPI_TOKEN_EXPOSURE",
                  "Code may persist TRIM_API_TOKEN; read the current environment value for "
                  "each backend call instead.",
                  path=match["path"], line=match["line"],
                  evidence=evidence_snippet(match["text"]))

    open_auth_match = next(
        iter(find_code_matches(source_files, r"\bopenAppAuth\s*\(", authored_only=True)), None)
    if open_auth_match is not None:
        missing_controls = []
        if not has_match(r"\bparseAppAuthCallback\s*\(", authored_text):
            missing_controls.append("parseAppAuthCallback")
        if not has_match(r"(?s)openAppAuth\s*\(.{0,1500}?\bstate\s*(?::|[,}])", authored_text):
            missing_controls.append("request state")
        if not has_match(r"(?is)\b\w*state\w*\s*(?:===|!==|==|!=)|(?:===|!==|==|!=)\s*\w*state\w*",
                         authored_text):
            missing_controls.append("callback state comparison")
        if missing_controls:
            audit.add("High", "OPENAPI_AUTH_CALLBACK_REQUIRED",
                      "openAppAuth requires a parsed callback and application-generated "
                      "state validation.",
                      path=open_auth_match["path"], line=open_auth_match["line"],
                      evidence="missing=" + ", ".join(missing_controls))

    if open_auth_match is not None:
        wildcard_match = next(iter(find_code_matches(
            source_files, r"""(?i)postMessage[^\r\n]*,\s*["']\*["']""", authored_only=True)), None)
        if wildcard_match is not None:
            audit.add("High", "OPENAPI_MESSAGE_ORIGIN_REQUIRED",
                      "Authorization callback postMessage uses a wildcard target origin; use "
                      "the exact same origin.",
                      path=wildcard_match["path"], line=wildcard_match["line"],
                      evidence=evidence_snippet(wildcard_match["text"]))

        listener_match = next(iter(find_code_matches(
            source_files, r"""addEventListener\s*\(\s*["']message["']""", authored_only=True)), None)
        if listener_match is not None and not has_match(r"\bevent\.origin\b", authored_text):
            audit.add("High", "OPENAPI_MESSAGE_ORIGIN_REQUIRED",
                      "An authorization message listener does not visibly reject events from "
                      "another origin.",
                      path=listener_match["path"], line=listener_match["line"],
                      evidence=evidence_snippet(listener_match["text"]))

    host_event_match = next(iter(find_code_matches(
        source_files, r"""\$on\s*\(\s*["']os/(?:theme|language)["']""", authored_only=True)), None)
    if host_event_match is not None and (
            not has_match(r"\bisWeb\b", authored_text)
            or not has_match(r"\bisStandaloneWeb\b", authored_text)):
        audit.add("Medium", "OPENAPI_HOST_EVENT_GUARD_REQUIRED",
                  "Theme/language host events require sdk.isWeb === true and "
                  "sdk.isStandaloneWeb === false guards.",
                  path=host_event_match["path"], line=host_event_match["line"],
                  evidence=evidence_snippet(host_event_match["text"]))

    gateway_entries = [name for name, value in entries if dict_get_ci(value, "gatewayPrefix")[1]]
    if gateway_entries:
        identity_match = next(iter(find_code_matches(
            source_files, IDENTITY_ASSIGNMENT_PATTERN + "|" + IDENTITY_DESTRUCTURE_PATTERN,
            authored_only=True)), None)
        if identity_match is not None:
            audit.add("High", "GATEWAY_CLIENT_IDENTITY_TRUST",
                      "Gateway application code assigns identity from client-controlled input; "
                      "bind identity to X-Trim-* headers from the gateway request instead.",
                      path=identity_match["path"], line=identity_match["line"],
                      evidence=evidence_snippet(identity_match["text"]))

    # -------------------------------------------------------------- ports/wizard
    manifest_port = manifest.get("service_port", "")
    for _, value in entries:
        port_value, port_found = dict_get_ci(value, "port")
        if (port_found and re.fullmatch(r"\d+", manifest_port or "")
                and re.fullmatch(r"\d+", text_value(port_value))
                and text_value(port_value) != manifest_port):
            audit.add("High", "ENTRY_PORT_MISMATCH",
                      "Desktop entry port does not match manifest.service_port.",
                      path=audit.rel(ui_path),
                      evidence=f"manifest={manifest_port}; entry={text_value(port_value)}")

    wizard_root = root / "wizard"
    wizard_files = sorted(
        path for path in (wizard_root.iterdir() if wizard_root.is_dir() else [])
        if path.is_file())
    port_wizard_fields: List[str] = []
    for wizard_file in wizard_files:
        wizard = read_json_file(audit, wizard_file, audit.rel(wizard_file))
        if wizard is None:
            continue
        steps = wizard if isinstance(wizard, list) else [wizard]
        for step in steps:
            items, items_found = dict_get_ci(step, "items")
            if not items_found:
                continue
            for item in (items if isinstance(items, list) else [items]):
                field_value, field_found = dict_get_ci(item, "field")
                if not field_found:
                    continue
                field = text_value(field_value)
                if not has_match(r"port", field):
                    continue
                port_wizard_fields.append(field)
                serialized = json.dumps(item, ensure_ascii=False, separators=(",", ":"))
                if "65535" not in serialized and '"max"' not in serialized:
                    audit.add("Medium", "PORT_RANGE_NOT_VALIDATED",
                              "Port wizard field '{0}' does not visibly enforce the 1..65535 "
                              "range; validate again in lifecycle code.".format(field),
                              path=audit.rel(wizard_file))

    protocol_files: List[Path] = []
    if isinstance(resource, dict):
        for key in resource:
            if isinstance(key, str) and key.casefold() in {"port-config", "systemd-unit"}:
                audit.add("Info", "COMMUNITY_RESOURCE",
                          f"Preserve compatibility resource '{key}' until fnpack/device "
                          "behavior proves it invalid.",
                          path=audit.rel(resource_path))

        port_config, port_config_found = dict_get_ci(resource, "port-config")
        if port_config_found:
            protocol_name, protocol_found = dict_get_ci(port_config, "protocol-file")
            if protocol_found:
                wanted = text_value(protocol_name)
                protocol_files = [
                    path for path in all_files if path.name.casefold() == wanted.casefold()]
                if not protocol_files:
                    audit.add("High", "PROTOCOL_FILE_MISSING",
                              "port-config references a protocol file that was not found.",
                              path=audit.rel(resource_path), evidence=wanted)
                elif len(protocol_files) > 1:
                    hashes = {sha256_file(path) for path in protocol_files}
                    audit.add("Info", "DUPLICATE_PROTOCOL_FILE",
                              "Multiple protocol files share the referenced name; verify which "
                              "copy enters the final FPK.",
                              path=audit.rel(protocol_files[0]),
                              evidence="copies currently match" if len(hashes) == 1 else "copies differ")

    protocol_port_pattern = r'^(src|dst)\.ports\s*=\s*"?(\d+)/(tcp|udp)'
    if re.fullmatch(r"\d+", manifest_port or ""):
        for protocol_file in protocol_files:
            for match in find_line_matches(protocol_file, protocol_port_pattern):
                matched = re.match(protocol_port_pattern, match["text"], re.IGNORECASE)
                if matched and matched.group(2) != manifest_port:
                    audit.add("High", "PROTOCOL_PORT_MISMATCH",
                              "Protocol-file port does not match manifest.service_port.",
                              path=audit.rel(protocol_file), line=match["line"],
                              evidence=f"manifest={manifest_port}; protocol={matched.group(2)}")

    if port_wizard_fields:
        for _, value in entries:
            port_value, port_found = dict_get_ci(value, "port")
            if port_found and re.fullmatch(r"\d+", text_value(port_value)):
                audit.add("Medium", "DYNAMIC_PORT_STATIC_ENTRY",
                          "A port wizard exists but the desktop entry contains a static numeric port.",
                          path=audit.rel(ui_path),
                          evidence="fields={0}; entry={1}".format(
                              ",".join(port_wizard_fields), text_value(port_value)))
        for protocol_file in protocol_files:
            if has_match(r'(src|dst)\.ports\s*=\s*"?\d+/', read_text(protocol_file)):
                audit.add("Medium", "DYNAMIC_PORT_STATIC_PROTOCOL",
                          "A port wizard exists but the compatibility protocol file contains "
                          "a static port.",
                          path=audit.rel(protocol_file),
                          evidence=",".join(port_wizard_fields))

    # ------------------------------------------------------------------ Docker
    docker_projects: List[Any] = []
    docker_project, docker_found = dict_get_ci(resource, "docker-project")
    if docker_found:
        projects, projects_found = dict_get_ci(docker_project, "projects")
        if projects_found:
            docker_projects = projects if isinstance(projects, list) else [projects]

    compose_files: List[Path] = []
    for project in docker_projects:
        path_value, path_found = dict_get_ci(project, "path")
        if not path_found or not text_value(path_value).strip():
            audit.add("High", "DOCKER_PROJECT_PATH_MISSING",
                      "docker-project entry has no path.", path=audit.rel(resource_path))
            continue
        compose_path = root / "app" / text_value(path_value) / "docker-compose.yaml"
        if not compose_path.is_file():
            audit.add("High", "DOCKER_COMPOSE_MISSING",
                      "Declared Docker project path has no docker-compose.yaml.",
                      path=audit.rel(resource_path), evidence=audit.rel(compose_path))
        else:
            compose_files.append(compose_path)

    main_path = root / "cmd" / "main"
    if docker_projects and main_path.is_file():
        main_text = read_text(main_path)
        managed_lifecycle = False
        for phase in ("start", "stop"):
            phase_pattern = re.compile(
                r"^\s*" + phase + r"\)\s*(?P<body>.*?);;",
                re.IGNORECASE | re.MULTILINE | re.DOTALL)
            phase_match = phase_pattern.search(main_text)
            if phase_match and has_match(
                    r"\bdocker(?:-compose|\s+compose|\s+start|\s+stop)\b",
                    phase_match.group("body")):
                managed_lifecycle = True
        if managed_lifecycle:
            audit.add("High", "DOCKER_LIFECYCLE_CONFLICT",
                      "cmd/main starts or stops Docker directly even though fnOS owns declared "
                      "docker-project lifecycle.",
                      path="cmd/main")

    for compose_path in compose_files:
        for match in find_line_matches(compose_path, r"^\s*image:\s*(.+)"):
            image = re.sub(r"^image:\s*", "", match["text"], flags=re.IGNORECASE).strip().strip("\"'")
            if not has_match(r"@sha256:", image):
                severity = "Medium" if (has_match(r":latest$", image)
                                        or not has_match(r":[^/]+$", image)) else "Low"
                audit.add(severity, "DOCKER_IMAGE_MUTABLE",
                          "Docker image is not pinned by digest; document the tag/update and "
                          "registry/mirror policy.",
                          path=audit.rel(compose_path), line=match["line"], evidence=image)

    # ------------------------------------------------- lifecycle shell patterns
    cmd_root = root / "cmd"
    if cmd_root.is_dir():
        for script_file in sorted(path for path in cmd_root.iterdir() if path.is_file()):
            try:
                if script_file.stat().st_size > MAX_LIFECYCLE_FILE_BYTES:
                    continue
            except OSError:
                continue
            relative = audit.rel(script_file)
            text = read_text(script_file)
            has_pipefail = (
                has_match(r"(?m)^\s*set\s+-(?:[^\r\n]*o\s+pipefail|[^\r\n]*o.*pipefail)", text)
                or has_match(r"(?m)^\s*set\s+-o\s+pipefail", text))

            for match in find_line_matches(script_file, r"(?<![A-Za-z0-9_])eval\s+"):
                audit.add("Medium", "SHELL_EVAL",
                          "Lifecycle code uses eval; dispatch allowlisted functions directly.",
                          path=relative, line=match["line"], evidence=match["text"])

            for match in find_line_matches(script_file, r"2>&1\s*\|(?!\|)"):
                if not has_pipefail:
                    audit.add("High", "PIPELINE_STATUS_MASKED",
                              "A lifecycle command is piped to a logger without visible "
                              "pipefail/status preservation.",
                              path=relative, line=match["line"], evidence=match["text"])

            temp_log_pattern = r'\$\(\s*basename\s+"?\$0"?\s*\).*?>\s*"?\$\{?TRIM_TEMP_LOGFILE'
            for match in find_line_matches(script_file, temp_log_pattern):
                if not has_match(r"2>&1|&>", match["text"]):
                    audit.add("Medium", "TEMP_LOG_STDOUT_ONLY",
                              "Lifecycle wrapper redirects stdout to TRIM_TEMP_LOGFILE but may "
                              "lose stderr.",
                              path=relative, line=match["line"], evidence=match["text"])

            destructive_pattern = r"(?i)\b(find|rm)\s+\$\{?TRIM_[A-Z0-9_]+\}?.*(-delete|-rf)"
            for match in find_line_matches(script_file, destructive_pattern):
                if not has_match(r'"\$\{TRIM_[A-Z0-9_]+:\?', match["text"]):
                    audit.add("High", "UNSAFE_DESTRUCTIVE_PATH",
                              "Destructive command uses an unguarded TRIM_* expansion; reject "
                              "empty/broad paths and quote the resolved target.",
                              path=relative, line=match["line"], evidence=match["text"])

            for match in find_line_matches(script_file, r"/var/apps/\$\{?TRIM_APPNAME\}?"):
                audit.add("Low", "HARDCODED_APP_PATH",
                          "Use the exact supplied TRIM_* path instead of reconstructing "
                          "/var/apps from TRIM_APPNAME.",
                          path=relative, line=match["line"], evidence=match["text"])

            for match in find_line_matches(script_file, r'export\s+"?\$\{?_key\}?='):
                audit.add("Medium", "DYNAMIC_ENV_IMPORT",
                          "A mutable file can populate arbitrary environment keys; allowlist "
                          "keys and use an escaped data format.",
                          path=relative, line=match["line"], evidence=match["text"])

            for match in find_line_matches(script_file, r"(?i)\bpkill\s+(-9\s+)?-x\s+"):
                audit.add("Low", "GLOBAL_PROCESS_CLEANUP",
                          "Exact-name pkill is global to the device; verify PID, executable, "
                          "and package identity before signaling.",
                          path=relative, line=match["line"], evidence=match["text"])

    # ---------------------------------------------- license and runtime inventory
    license_evidence = [
        path for path in all_files
        if has_match(r"^(?i:LICENSE|COPYING|NOTICE)(?:\.|$)", path.name)
        or has_match(r"(?i)third[-_]?party.*(?:license|notice)", path.name)]
    if not license_evidence:
        audit.add("Medium", "LICENSE_EVIDENCE_MISSING",
                  "No license or notice evidence was found in the package tree; verify "
                  "application and third-party distribution obligations.")

    elf_machines: Counter = Counter()
    elf_count = dll_count = so_count = pdb_count = 0
    runtime_bytes = 0
    for path in all_files:
        try:
            size = path.stat().st_size
        except OSError:
            continue

        is_runtime_artifact = False
        extension = path.suffix.lower()
        if extension == ".dll":
            dll_count += 1
            is_runtime_artifact = True
        elif extension == ".so":
            so_count += 1
            is_runtime_artifact = True
        elif extension == ".pdb":
            pdb_count += 1
            is_runtime_artifact = True

        machine = elf_machine(path)
        if machine is None:
            if is_runtime_artifact:
                runtime_bytes += size
            continue

        is_runtime_artifact = True
        runtime_bytes += size
        elf_count += 1
        elf_machines[machine] += 1

        if "platform" in manifest:
            expected = manifest["platform"].strip().casefold()
            matches_platform = (
                (expected == "x86" and machine in (3, 62))
                or (expected == "arm" and machine in (40, 183))
                or expected == "all")
            if not matches_platform:
                audit.add("High", "NATIVE_ARCH_MISMATCH",
                          "ELF architecture does not match manifest.platform.",
                          path=audit.rel(path),
                          evidence=f"platform={manifest['platform']}; e_machine={machine}")
            elif expected == "all":
                audit.add("High", "NATIVE_BINARY_WITH_ALL_PLATFORM",
                          "Package declares platform=all but contains an architecture-specific "
                          "ELF binary.",
                          path=audit.rel(path), evidence=f"e_machine={machine}")

    if pdb_count > 0:
        audit.add("Low", "DEBUG_SYMBOLS_BUNDLED",
                  f"Package contains {pdb_count} PDB debug-symbol file(s); retain intentionally "
                  "or remove after preserving diagnostics elsewhere.")
    if (dll_count >= 50 or so_count >= 10) and runtime_bytes >= 1024 * 1024:
        audit.add("Low", "EMBEDDED_RUNTIME_INVENTORY",
                  "Large embedded runtime detected; record runtime version, licenses, "
                  "SBOM/CVE posture, and package-size rationale.",
                  evidence=f"dll={dll_count}; so={so_count}; elf={elf_count}")

    # ------------------------------------------------------------------ report
    ordered = sorted(audit.findings, key=lambda finding: (
        SEVERITY_RANK.get(finding["severity"], 9),
        (finding["code"] or "").casefold(),
        (finding["path"] or "").casefold(),
        finding["line"] if finding["line"] is not None else 0,
    ))

    summary = {
        "high": sum(1 for f in ordered if f["severity"] == "High"),
        "medium": sum(1 for f in ordered if f["severity"] == "Medium"),
        "low": sum(1 for f in ordered if f["severity"] == "Low"),
        "info": sum(1 for f in ordered if f["severity"] == "Info"),
        "total": len(ordered),
    }

    package_bytes = 0
    for path in all_files:
        try:
            package_bytes += path.stat().st_size
        except OSError:
            continue

    return {
        "status": "completed",
        "project": str(root),
        "appname": manifest.get("appname"),
        "summary": summary,
        "inventory": {
            "package_bytes": package_bytes,
            "elf": elf_count,
            "elf_machines": [{"e_machine": machine, "count": count}
                             for machine, count in sorted(elf_machines.items())],
            "dll": dll_count,
            "shared_objects": so_count,
            "pdb": pdb_count,
            "runtime_bytes": runtime_bytes,
            "license_files": len(license_evidence),
            "docker_projects": len(docker_projects),
            "wizard_port_fields": port_wizard_fields,
        },
        "findings": ordered,
    }


def render_text(result: dict) -> str:
    summary = result["summary"]
    lines = [
        f"fnOS project audit: {result['project']}",
        "Findings: high={0} medium={1} low={2} info={3}".format(
            summary["high"], summary["medium"], summary["low"], summary["info"]),
    ]
    for finding in result["findings"]:
        location = ""
        if finding["path"]:
            location = (" [{0}]".format(finding["path"]) if finding["line"] is None
                        else " [{0}:{1}]".format(finding["path"], finding["line"]))
        lines.append("[{0}] {1}{2} - {3}".format(
            finding["severity"], finding["code"], location, finding["message"]))
        if finding["evidence"] and finding["evidence"].strip():
            lines.append("  Evidence: " + finding["evidence"])
    return "\n".join(lines)


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Static audit for an fnOS application package.")
    parser.add_argument("--project-path", "-ProjectPath", dest="project_path",
                        required=True, help="Package root directory")
    parser.add_argument("--format", "-Format", dest="format",
                        choices=("text", "json"), default="text",
                        help="Report format (default: text)")
    args = parser.parse_args(argv)

    project = Path(args.project_path)
    if not project.is_dir():
        print(f"ProjectPath is not a directory: {args.project_path}", file=sys.stderr)
        return 1
    root = project.resolve()

    result = audit_project(root)
    if args.format == "json":
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        print(render_text(result))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
