#!/usr/bin/env python3
"""Isolated audit regressions. Never import or run application lifecycle code."""
import contextlib
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[3] / 'apps/tripstar'
SPEC = importlib.util.spec_from_file_location('fnos_audit_regression', HERE / 'audit_fnos_project.py')
AUDIT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUDIT)
PHASES = ('install_init', 'install_callback', 'upgrade_init', 'upgrade_callback',
          'uninstall_init', 'uninstall_callback')
EVIDENCE = {
    'schema': 'tripstar-systemd-nonroot-v1',
    'controller': 'app/bin/lifecycle.py',
    'server': 'app/bin/run-server.py',
    'unit_template': 'app/systemd/fnos-tripstar.service.in',
    'setup': 'app/bin/setup-runtime.py',
}


def put(root, relative, text):
    target = root / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text, encoding='utf-8')
    return target


def replace(root, relative, before, after):
    target = root / relative
    text = target.read_text(encoding='utf-8')
    if text.count(before) != 1:
        raise AssertionError('Test mutation must have exactly one anchor: ' + relative + ': ' + before)
    target.write_text(text.replace(before, after, 1), encoding='utf-8')


def pin_controller(root):
    source = root / EVIDENCE['controller']
    entry = root / 'cmd/main'
    if not source.is_file() or not entry.is_file():
        return
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    text, count = re.subn(r"(?m)^expected = '[0-9a-f]{64}'$",
                          "expected = '" + digest + "'", entry.read_text())
    if count == 1:
        put(root, 'cmd/main', text)


def metadata(root, key, value):
    data = json.loads((root / 'audit-native-runtime.json').read_text())
    data[key] = value
    put(root, 'audit-native-runtime.json', json.dumps(data))


def unit(root, before, after):
    replace(root, EVIDENCE['unit_template'], before, after)


@contextlib.contextmanager
def fixture(native=False, run_as='package'):
    with tempfile.TemporaryDirectory(prefix='fnos-audit-regression-') as temporary:
        root = Path(temporary) / 'project'
        root.mkdir()
        put(root, 'manifest', '\n'.join((
            'appname=tripstar', 'version=1.0.0', 'display_name=Audit fixture',
            'desc=Isolated regression', 'source=thirdparty', 'platform=x86',
            'service_port=17860', 'desktop_uidir=ui', 'desktop_applaunchname=tripstar.main',
            'os_min_version=1.2.0401', '',
        )))
        put(root, 'LICENSE', 'Regression fixture license evidence\n')
        put(root, 'config/resource', '{}')
        put(root, 'config/privilege', json.dumps({
            'defaults': {'run-as': 'root' if native else run_as},
            'username': 'tripstar', 'groupname': 'tripstar',
        }))
        put(root, 'app/ui/config', json.dumps({'.url': {'tripstar.main': {
            'type': 'url', 'title': 'Audit fixture', 'protocol': 'http',
            'port': '17860', 'url': '/', 'allUsers': False,
        }}}))
        if native:
            # These are the real packaging sources, not the engine's expected
            # AST models. No package code is ever imported in this test.
            for relative in (*EVIDENCE.values(), 'cmd/main', *('cmd/' + name for name in PHASES)):
                if relative == EVIDENCE['schema']:
                    continue
                original = PROJECT / relative
                if not original.is_file():
                    raise AssertionError('Native regression source is missing: ' + str(original))
                target = root / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(original, target)
            put(root, 'audit-native-runtime.json', json.dumps(EVIDENCE))
        else:
            put(root, 'cmd/main', '#!/bin/sh\ncase "$1" in\nstart|stop) exit 0 ;;\nstatus) exit 3 ;;\nesac\n')
        yield root


class NativeProofTests(unittest.TestCase):
    def assert_rejected(self, root, label='', *, repin=True):
        if repin:
            pin_controller(root)
        result = AUDIT.audit_project(root)
        found = [item for item in result['findings'] if item['code'] == 'ROOT_RUNTIME']
        self.assertEqual(len(found), 1, label + ': ' + json.dumps(result['findings']))
        self.assertEqual(found[0]['severity'], 'Medium')
        self.assertIn('Native runtime proof:', found[0]['evidence'])
        self.assertTrue(found[0]['evidence'].split(':', 1)[1].strip())

    def test_real_native_sources_have_raw_zero_findings(self):
        with fixture(native=True) as root:
            result = AUDIT.audit_project(root)
            self.assertEqual(result['summary'], {'high': 0, 'medium': 0, 'low': 0, 'info': 0, 'total': 0})
            self.assertEqual(result['findings'], [])

    def test_comments_formatting_and_literal_diagnostics_are_not_fingerprints(self):
        with fixture(native=True) as root:
            replace(root, 'app/bin/lifecycle.py', "UNIT = 'fnos-tripstar.service'",
                    '# harmless comment\nUNIT  =  "fnos-tripstar.service"')
            replace(root, 'app/bin/lifecycle.py', "raise LifecycleError('Exactly one lifecycle action is required')",
                    'raise LifecycleError("Updated inert diagnostic")')
            pin_controller(root)
            result = AUDIT.audit_project(root)
            self.assertEqual(result['findings'], [])

    def test_noop_hooks_succeed_without_app_files_or_trim_environment(self):
        with fixture(native=True) as root:
            self.assertEqual(AUDIT.audit_project(root)['findings'], [])
            # Simulate the official pre-extraction/post-cleanup hook boundaries.
            # Only this isolated fixture is removed; no installed SDK is touched.
            shutil.rmtree(root / 'app')
            for phase in ('install_init', 'uninstall_callback'):
                with self.subTest(phase=phase):
                    completed = subprocess.run(
                        ['/bin/sh', str(root / 'cmd' / phase)],
                        env={'PATH': '/usr/bin:/bin'}, capture_output=True,
                        text=True, timeout=5, check=False)
                    self.assertEqual(completed.returncode, 0, completed.stderr)
                    self.assertEqual(completed.stdout, '')
                    self.assertEqual(completed.stderr, '')

    def test_controlled_phases_keep_the_app_environment_gate(self):
        with fixture(native=True) as root:
            for phase in ('start', 'stop', 'status', 'install_callback', 'upgrade_init',
                          'upgrade_callback', 'uninstall_init'):
                with self.subTest(phase=phase):
                    completed = subprocess.run(
                        ['/bin/sh', str(root / 'cmd/main'), phase],
                        env={'PATH': '/usr/bin:/bin'}, capture_output=True,
                        text=True, timeout=5, check=False)
                    self.assertNotEqual(completed.returncode, 0)
                    self.assertIn('missing TRIM_APPDEST', completed.stderr)

    def test_noop_phase_execution_or_cleanup_drift_stays_root(self):
        main = 'cmd/main'
        controller = 'app/bin/lifecycle.py'
        controlled = '    start|stop|status|install_callback|upgrade_init|upgrade_callback|uninstall_init)\n'
        edits = (
            (main, '        exit 0\n',
             '        exec "$PYTHON" "$TRIM_APPDEST/bin/run-server.py"\n        exit 0\n'),
            (main, '        exit 0\n',
             '        python3 -m backend.app.api.main\n        exit 0\n'),
            ('cmd/install_init', '/main" install_init', '/main" start'),
            ('cmd/uninstall_callback', '/main" uninstall_callback', '/main" stop'),
            (main, controlled, controlled + '        exit 0\n'),
            (main, 'case "$phase" in\n',
             ': "${TRIM_APPDEST:?missing TRIM_APPDEST}"\ncase "$phase" in\n'),
            (main, 'case "$phase" in\n',
             'PYTHON=/var/apps/python312/target/bin/python3.12\n'
             '[ -x "$PYTHON" ] || exit 1\ncase "$phase" in\n'),
            (main, '    install_init|uninstall_callback)\n',
             '    install_init|uninstall_callback|start)\n'),
            (controller, "        if action == 'install_init':\n            return 0\n",
             "        if action == 'install_init':\n            return self.start()\n"),
            (controller, "        if action == 'install_init':\n            return 0\n",
             "        if action == 'install_init':\n"
             "            subprocess.run([PYTHON, '-m', 'backend.app.api.main'])\n            return 0\n"),
            (controller, "        if action == 'uninstall_callback':\n            return 0\n",
             "        if action == 'uninstall_callback':\n            return self.uninstall()\n"),
            (controller, "        if action == 'uninstall_init':\n            return self.uninstall()\n",
             "        if action == 'uninstall_init':\n            return self.stop()\n"),
        )
        for relative, before, after in edits:
            with self.subTest(file=relative, change=after), fixture(native=True) as root:
                replace(root, relative, before, after)
                self.assert_rejected(root, after)

    def test_evidence_failures_stay_root(self):
        cases = {
            'missing metadata': lambda r: (r / 'audit-native-runtime.json').unlink(),
            'metadata flag is not a waiver': lambda r: metadata(r, 'verified', True),
            'metadata root identity is not a waiver': lambda r: metadata(r, 'username', 'tripstar'),
            'escaping metadata': lambda r: metadata(r, 'controller', '../../outside.py'),
            'absolute metadata': lambda r: metadata(r, 'server', '/tmp/run-server.py'),
            'incorrect template metadata': lambda r: metadata(r, 'unit_template', 'app/systemd/dummy.service.in'),
            'missing controller': lambda r: (r / EVIDENCE['controller']).unlink(),
            'missing server': lambda r: (r / EVIDENCE['server']).unlink(),
            'missing setup': lambda r: (r / EVIDENCE['setup']).unlink(),
            'extra template': lambda r: put(r, 'app/systemd/dummy.service.in', '[Service]\nUser=root\n'),
            'malformed metadata': lambda r: put(r, 'audit-native-runtime.json', '{'),
            'duplicate metadata': lambda r: put(r, 'audit-native-runtime.json',
                json.dumps(EVIDENCE)[:-1] + ', "schema":"tripstar-systemd-nonroot-v1"}'),
            'writable controller': lambda r: (r / EVIDENCE['controller']).chmod(0o666),
            'nonexecutable main': lambda r: (r / 'cmd/main').chmod(0o644),
            'nonexecutable callback': lambda r: (r / 'cmd/upgrade_callback').chmod(0o644),
            'oversized controller': lambda r: put(r, EVIDENCE['controller'], '#' * (AUDIT.MAX_LIFECYCLE_FILE_BYTES + 1)),
        }
        for label, mutate in cases.items():
            with self.subTest(case=label), fixture(native=True) as root:
                mutate(root)
                self.assert_rejected(root, label)

    def test_symlink_files_and_ancestors_stay_root(self):
        for relative in ('app/bin/lifecycle.py', 'app/bin/run-server.py',
                         'app/systemd/fnos-tripstar.service.in', 'cmd/main', 'audit-native-runtime.json'):
            with self.subTest(file=relative), fixture(native=True) as root:
                target = root / relative
                outside = root.parent / 'outside-source'
                shutil.copy2(target, outside)
                target.unlink()
                target.symlink_to(outside)
                self.assert_rejected(root)
        with fixture(native=True) as root:
            outside = root.parent / 'outside-bin'
            shutil.move(root / 'app/bin', outside)
            (root / 'app/bin').symlink_to(outside, target_is_directory=True)
            self.assert_rejected(root)

    def test_systemd_privilege_and_execution_mutations_stay_root(self):
        edits = (
            ('User=tripstar', 'User=root'), ('Group=tripstar', 'Group=root'),
            ('User=tripstar', 'User=0'), ('Group=tripstar', 'Group=0'),
            ('User=tripstar', 'User=${TRIM_USERNAME}'), ('Group=tripstar', 'Group=%i'),
            ('ExecStart=:', 'ExecStart=+'), ('ExecStart=:', 'ExecStart=!'),
            ('ExecStart=:', 'ExecStart=!!'), ('ExecStart=:', 'ExecStart=+:'),
            ('ExecStart=:@APP_PYTHON@ @SERVER_SCRIPT@', 'ExecStart=/bin/sh -c "python backend/app/api/main.py"'),
            ('NoNewPrivileges=true', 'NoNewPrivileges=false'),
            ('KillMode=control-group', 'KillMode=process'), ('Restart=always', 'Restart=no'),
            ('EnvironmentFile=@ENV_FILE@', 'EnvironmentFile=/tmp/environment'),
            ('ReadWritePaths=@STATE_ROOT@', 'ReadWritePaths=/'),
        )
        extras = (
            'User=root', 'User=tripstar', 'ExecStart=:/bin/false', 'ExecStart=',
            'ExecStartPre=+/usr/bin/id', 'ExecStartPost=/bin/sh -c id',
            'ExecStop=/bin/sh -c id', 'ExecCondition=+/usr/bin/id',
            'AmbientCapabilities=CAP_SETUID', 'CapabilityBoundingSet=CAP_SETUID',
            'Environment=PYTHONPATH=/tmp', 'PermissionsStartOnly=true',
            '[Service]\nUser=tripstar', '[Install]\nWantedBy=multi-user.target',
        )
        for before, after in edits:
            with self.subTest(change=after), fixture(native=True) as root:
                unit(root, before, after)
                self.assert_rejected(root, after)
        for extra in extras:
            with self.subTest(extra=extra), fixture(native=True) as root:
                target = root / EVIDENCE['unit_template']
                target.write_text(target.read_text() + extra + '\n')
                self.assert_rejected(root, extra)

    def test_controller_and_wrapper_bypasses_stay_root(self):
        controller = 'app/bin/lifecycle.py'
        edits = (
            ('cmd/main', 'exec "$PYTHON" -I -B - "$phase" <<\'PY\'',
             'exec "$PYTHON" "$TRIM_APPDEST/backend/app/api/main.py"'),
            ('cmd/main', 'exec "$PYTHON" -I ', 'exec "$PYTHON" '),
            ('cmd/install_callback', '/main" install_callback', '/main" start'),
            (controller, "template = self.app / 'systemd' / (UNIT + '.in')",
             "template = self.app / 'systemd' / 'dummy.service.in'"),
            (controller, "self.server = app / 'bin/run-server.py'",
             "self.server = app / 'backend/app/api/main.py'"),
            (controller, "UNIT = 'fnos-tripstar.service'", "UNIT = 'foreign.service'"),
            (controller, "RUNUSER, '-u', 'tripstar', '-g', 'tripstar'",
             "RUNUSER, '-u', 'root', '-g', 'root'"),
            (controller, "command([SYSTEMCTL, 'start', UNIT], timeout=60)",
             "command(['/bin/sh', '-c', 'python backend/app/api/main.py'], timeout=60)"),
            (controller, "command([SYSTEMCTL, 'start', UNIT], timeout=60)",
             "command([SYSTEMCTL, 'start', 'foreign.service'], timeout=60)"),
            (controller, "set(keys) - allowed", 'False'),
            (controller, "or values.get('DropInPaths')", 'or False'),
            (controller, 'any(field != str(self.uid) for field in fields)', 'False'),
            (controller, "expected_executable = self.python.resolve()", "expected_executable = Path('/usr/bin/python3')"),
            (controller, 'text = self.rendered_unit()', 'text = "[Service]\\nUser=root\\nExecStart=/bin/sh\\n"'),
            (controller, 'import errno\n', 'import backend.app.api.main\nimport errno\n'),
            (controller, '    def start(self):\n',
             '    def start(self):\n        listener = socket.socket()\n        listener.listen()\n'),
            (controller, '    def start(self):\n',
             '    def start(self):\n        import backend.app.api.main\n'),
            (controller, "result = subprocess.run(args, env=COMMAND_ENV, capture_output=True,",
             "result = subprocess.run(args, env=COMMAND_ENV, shell=True, capture_output=True,"),
            (controller, "SYSTEMCTL = '/usr/bin/systemctl'", "SYSTEMCTL = os.environ['SYSTEMCTL']"),
            (controller, "raise LifecycleError('Exactly one lifecycle action is required')",
             "raise LifecycleError(__import__('os').system('id'))"),
        )
        for relative, before, after in edits:
            with self.subTest(change=after), fixture(native=True) as root:
                replace(root, relative, before, after)
                self.assert_rejected(root, after)
        with fixture(native=True) as root:
            put(root, 'cmd/extra', '#!/bin/sh\npython backend/app/api/main.py\n')
            self.assert_rejected(root)
        with fixture(native=True) as root:
            target = root / controller
            target.write_text(target.read_text() + '\ndef unused_root_backend():\n    import backend.app.api.main\n')
            self.assert_rejected(root)

    def test_package_group_lookup_and_import_drift_stay_root(self):
        controller = 'app/bin/lifecycle.py'
        lookup = "grp.getgrnam('tripstar').gr_gid"
        edits = (
            ('root group', lookup, "grp.getgrnam('root').gr_gid"),
            ('primary shared group', lookup, "grp.getgrnam('AppUsers').gr_gid"),
            ('foreign group', lookup, "grp.getgrnam('foreign').gr_gid"),
            ('dynamic package group', lookup, "grp.getgrnam(os.environ['TRIM_GROUPNAME']).gr_gid"),
            ('dynamic fallback group', lookup, "grp.getgrnam(os.environ.get('GROUP', 'tripstar')).gr_gid"),
            ('root numeric lookup', lookup, 'grp.getgrgid(0).gr_gid'),
            ('environment numeric lookup', lookup, "grp.getgrgid(int(os.environ['TRIM_GID'])).gr_gid"),
            ('wrong group field', lookup, "grp.getgrnam('tripstar').gr_mem"),
            ('aliased group module', 'import grp\n', 'import grp as groupdb\n'),
            ('duplicate group import', 'import grp\n', 'import grp\nimport grp\n'),
        )
        for label, before, after in edits:
            with self.subTest(case=label), fixture(native=True) as root:
                replace(root, controller, before, after)
                self.assert_rejected(root, label)

    def test_package_gid_validation_and_primary_gid_regressions_stay_root(self):
        controller = 'app/bin/lifecycle.py'
        check = "if not re.fullmatch(r'[1-9][0-9]*', supplied) or supplied != actual:"
        edits = (
            ('zero group provider', "group_id = grp.getgrnam('tripstar').gr_gid", 'group_id = 0'),
            ('zero expected gid', 'str(group_id)', "'0'"),
            ('process group provider', 'str(group_id)', 'str(os.getgid())'),
            ('old primary gid source', 'str(group_id)', "command([ID, '-g', 'tripstar'], timeout=10).strip()"),
            ('environment self-comparison', 'str(group_id)', "os.environ.get('TRIM_GID', '')"),
            ('removed equality validation', check, "if not re.fullmatch(r'[1-9][0-9]*', supplied):"),
            ('removed positive id validation', check, 'if supplied != actual:'),
            ('zero-accepting id validation', check, "if not re.fullmatch(r'[0-9]+', supplied) or supplied != actual:"),
            ('missing group falls back to root',
             "except KeyError as exc:\n            raise LifecycleError('TripStar package group is missing') from exc",
             'except KeyError:\n            group_id = 0'),
            ('validated identity discarded', 'ids.append(int(supplied))', 'ids.append(0)'),
        )
        for label, before, after in edits:
            with self.subTest(case=label), fixture(native=True) as root:
                replace(root, controller, before, after)
                self.assert_rejected(root, label)

    def test_root_control_path_and_file_binding_drift_stay_root(self):
        controller = 'app/bin/lifecycle.py'
        constant = "CONTROL_ROOT = Path('/etc/fnos-tripstar')"
        edits = (
            ('dynamic appconf control root', constant, "CONTROL_ROOT = Path(os.environ['TRIM_PKGETC'])"),
            ('broad control root', constant, "CONTROL_ROOT = Path('/etc')"),
            ('foreign control root', constant, "CONTROL_ROOT = Path('/etc/foreign')"),
            ('temporary control root', constant, "CONTROL_ROOT = Path('/tmp/fnos-tripstar')"),
            ('appconf control binding', 'self.control = CONTROL_ROOT', 'self.control = etc'),
            ('mutable state control binding', 'self.control = CONTROL_ROOT', 'self.control = self.var'),
            ('dynamic context control binding', 'self.control = CONTROL_ROOT', "self.control = Path(os.environ['CONTROL_ROOT'])"),
            ('appconf unit file', 'self.unit_file = self.control / UNIT', 'self.unit_file = self.etc / UNIT'),
            ('appconf environment file', "self.env_file = self.control / 'fnos-tripstar.env'", "self.env_file = self.etc / 'fnos-tripstar.env'"),
        )
        for label, before, after in edits:
            with self.subTest(case=label), fixture(native=True) as root:
                replace(root, controller, before, after)
                self.assert_rejected(root, label)

    def test_root_control_directory_guards_and_creation_drift_stay_root(self):
        controller = 'app/bin/lifecycle.py'
        parent_check = (
            'if (parent.resolve() != parent or not stat.S_ISDIR(info.st_mode)\n'
            '                or info.st_uid != 0 or stat.S_IMODE(info.st_mode) & 0o022):')
        directory_check = (
            'if (not stat.S_ISDIR(info.st_mode) or info.st_uid != 0\n'
            '                or stat.S_IMODE(info.st_mode) & 0o022):')
        creation = (
            '    def prepare(self):\n'
            '        self.guard_control(absent_ok=True)\n'
            '        self.control.mkdir(mode=0o700, exist_ok=True)\n'
            '        self.guard_control()\n')
        verification = '        self.guard_control()\n        self.guard_link()\n'
        edits = (
            ('removed fixed path check', 'if self.control != CONTROL_ROOT:', 'if False:'),
            ('removed parent canonical path check', parent_check, parent_check.replace('parent.resolve() != parent', 'False')),
            ('parent symlink following', 'info = parent.lstat()', 'info = parent.stat()'),
            ('control symlink following', 'info = self.control.lstat()', 'info = self.control.stat()'),
            ('removed parent owner check', parent_check, parent_check.replace('info.st_uid != 0', 'False')),
            ('removed parent directory check', parent_check, parent_check.replace('not stat.S_ISDIR(info.st_mode)', 'False')),
            ('removed parent write-mode check', parent_check, parent_check.replace('stat.S_IMODE(info.st_mode) & 0o022', 'False')),
            ('removed control directory check', directory_check, directory_check.replace('not stat.S_ISDIR(info.st_mode)', 'False')),
            ('removed control owner check', directory_check, directory_check.replace('info.st_uid != 0', 'False')),
            ('removed control write-mode check', directory_check, directory_check.replace('stat.S_IMODE(info.st_mode) & 0o022', 'False')),
            ('unconditional missing control allowance', 'except FileNotFoundError:\n            if absent_ok:', 'except FileNotFoundError:\n            if True:'),
            ('removed constructor control validation', 'ctx.guard_control(absent_ok=True)', 'pass'),
            ('removed creation parent validation', creation, creation.replace('        self.guard_control(absent_ok=True)\n', '')),
            ('removed post-creation validation', creation, creation.replace('        self.guard_control()\n', '')),
            ('public control directory creation', creation, creation.replace('mode=0o700', 'mode=0o777')),
            ('appconf directory creation', creation, creation.replace('self.control.mkdir', 'self.etc.mkdir')),
            ('removed loaded-unit control validation', verification, '        self.guard_link()\n'),
            ('missing loaded-unit control allowed', verification, '        self.guard_control(absent_ok=True)\n        self.guard_link()\n'),
        )
        for label, before, after in edits:
            with self.subTest(case=label), fixture(native=True) as root:
                replace(root, controller, before, after)
                self.assert_rejected(root, label)

    def test_protected_loader_fd_bounds_and_execution_drift_stay_root(self):
        main = 'cmd/main'
        opening = 'descriptor = os.open(controller, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)'
        edits = (
            ('loader follows symlinks', opening, opening.replace(' | os.O_NOFOLLOW', '')),
            ('loader blocks on FIFO', opening, opening.replace(' | os.O_NONBLOCK', '')),
            ('loader pathname stat race', 'info = os.fstat(handle.fileno())', 'info = controller.stat()'),
            ('loader accepts nonregular source', 'not stat.S_ISREG(info.st_mode)', 'False'),
            ('loader accepts foreign owner', 'info.st_uid != 0', 'False'),
            ('loader accepts world writes', 'stat.S_IMODE(info.st_mode) & 0o002', 'False'),
            ('loader ignores stat bound', 'or info.st_size > 131072', ''),
            ('loader unbounded read', 'handle.read(131073)', 'handle.read()'),
            ('loader ignores growing bound', 'len(source) > 131072 or ', ''),
            ('loader ignores checksum', 'digest != expected', 'False'),
            ('loader reopens source for execution', "compile(source, str(controller), 'exec')", "compile(controller.read_bytes(), str(controller), 'exec')"),
            ('loader dynamic source path', "Path(os.environ['TRIM_APPDEST']) / 'bin/lifecycle.py'", "Path(os.environ['CONTROLLER'])"),
            ('loader overrides phase', 'sys.argv = [str(controller), sys.argv[1]]', "sys.argv = [str(controller), 'start']"),
            ('loader root application import', 'import hashlib\n', 'import backend.app.api.main\nimport hashlib\n'),
            ('loader allows SDK bytecode writes', 'exec "$PYTHON" -I -B - ', 'exec "$PYTHON" -I - '),
        )
        for label, before, after in edits:
            with self.subTest(case=label), fixture(native=True) as root:
                replace(root, main, before, after)
                self.assert_rejected(root, label, repin=False)

    def test_pinned_asset_reader_and_root_file_guard_drift_stay_root(self):
        controller = EVIDENCE['controller']
        opening = 'descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)'
        check = (
            'if (not stat.S_ISREG(info.st_mode) or info.st_uid != 0\n'
            '                or stat.S_IMODE(info.st_mode) & 0o002 or info.st_size > 131072):')
        edits = (
            ('asset follows symlinks', opening, opening.replace(' | os.O_NOFOLLOW', '')),
            ('asset blocks on FIFO', opening, opening.replace(' | os.O_NONBLOCK', '')),
            ('asset pathname stat race', 'info = os.fstat(handle.fileno())', 'info = path.stat()'),
            ('asset accepts nonregular file', check, check.replace('not stat.S_ISREG(info.st_mode)', 'False')),
            ('asset accepts foreign owner', check, check.replace('info.st_uid != 0', 'False')),
            ('asset accepts world writes', check, check.replace('stat.S_IMODE(info.st_mode) & 0o002', 'False')),
            ('asset ignores stat bound', check, check.replace(' or info.st_size > 131072', '')),
            ('asset unbounded read', 'data = handle.read(131073)', 'data = handle.read()'),
            ('asset ignores growing bound', 'if len(data) > 131072:', 'if False:'),
            ('asset ignores checksum', 'if hashlib.sha256(data).hexdigest() != digest:', 'if False:'),
            ('asset rereads verified pathname', "return data.decode('utf-8')", "return path.read_text(encoding='utf-8')"),
            ('template bypasses pin', 'text = package_text(template, TEMPLATE_SHA256)', "text = template.read_text(encoding='utf-8')"),
            ('template uses wrong pin', 'text = package_text(template, TEMPLATE_SHA256)', 'text = package_text(template, SETUP_SHA256)'),
            ('root unit guard replaced by asset pin', 'check_root_file(self.unit_file)', 'package_text(self.unit_file, TEMPLATE_SHA256)'),
        )
        for label, before, after in edits:
            with self.subTest(case=label), fixture(native=True) as root:
                replace(root, controller, before, after)
                self.assert_rejected(root, label)

    def test_protected_content_pins_are_binding_not_ast_waivers(self):
        for label in ('wrong controller pin', 'malformed controller pin', 'duplicate controller pin',
                      'controller stale pin', 'setup stale pin', 'template stale pin'):
            with self.subTest(case=label), fixture(native=True) as root:
                digest = hashlib.sha256((root / EVIDENCE['controller']).read_bytes()).hexdigest()
                anchor = "expected = '" + digest + "'"
                if label == 'wrong controller pin':
                    replace(root, 'cmd/main', anchor, "expected = '" + '0' * 64 + "'")
                elif label == 'malformed controller pin':
                    replace(root, 'cmd/main', anchor, "expected = '" + '0' * 63 + "'")
                elif label == 'duplicate controller pin':
                    replace(root, 'cmd/main', anchor, anchor + '\n' + anchor)
                else:
                    asset = {'controller stale pin': 'controller', 'setup stale pin': 'setup',
                             'template stale pin': 'unit_template'}[label]
                    target = root / EVIDENCE[asset]
                    target.write_text(target.read_text() + '\n# Content must remain bound to its pin.\n')
                self.assert_rejected(root, label, repin=False)
        with fixture(native=True) as root:
            replace(root, EVIDENCE['controller'], "command([SYSTEMCTL, 'start', UNIT], timeout=60)",
                    "command(['/bin/sh', '-c', 'python backend/app/api/main.py'], timeout=60)")
            pin_controller(root)
            self.assert_rejected(root, 'malicious controller re-pinned')
        with fixture(native=True) as root:
            unit(root, 'Group=tripstar', 'Group=root')
            digest = hashlib.sha256((root / EVIDENCE['unit_template']).read_bytes()).hexdigest()
            replace(root, EVIDENCE['controller'],
                    "TEMPLATE_SHA256 = 'c5d2ea36996b323d43606eace7d947d1e4a924f3c2270ed273bebdee2c668435'",
                    "TEMPLATE_SHA256 = '" + digest + "'")
            pin_controller(root)
            self.assert_rejected(root, 'root template re-pinned')

    def test_verified_setup_stdin_and_package_identity_drift_stay_root(self):
        controller = EVIDENCE['controller']
        execution = "PYTHON, '-I', '-B', '-c', SETUP_RUNNER, str(setup_file), SETUP_SHA256"
        edits = (
            ('setup executed as root', "RUNUSER, '-u', 'tripstar', '-g', 'tripstar', '--', '/usr/bin/env', '-i',", "'/usr/bin/env', '-i',"),
            ('setup lacks isolated interpreter', execution, execution.replace("'-I', ", '')),
            ('setup allows SDK bytecode writes', execution, execution.replace("'-B', ", '')),
            ('setup reopens mutable filename', execution, 'PYTHON, str(setup_file)'),
            ('setup verified stdin discarded', 'input_text=setup_source', 'input_text=None'),
            ('setup bypasses source pin', 'setup_source = package_text(setup_file, SETUP_SHA256)', 'setup_source = setup_file.read_text()'),
            ('setup runner reopens pathname', '"source = sys.stdin.read(131073)\\n"', '"source = open(path).read()\\n"'),
            ('setup runner unbounded stdin', '"source = sys.stdin.read(131073)\\n"', '"source = sys.stdin.read()\\n"'),
            ('setup runner drops revision pin', "'__verified_source_sha256__': digest", "'unverified_source_sha256': digest"),
        )
        for label, before, after in edits:
            with self.subTest(case=label), fixture(native=True) as root:
                replace(root, controller, before, after)
                self.assert_rejected(root, label)

    def test_scalar_paths_and_word_list_escaping_drift_stay_root(self):
        controller = EVIDENCE['controller']
        scalar = "return str(value).replace('%', '%%')"
        words = r'''text = str(value).replace('\\', '\\\\').replace('"', '\\"').replace('%', '%%')'''
        edits = (
            ('quoted EnvironmentFile scalar', "'@ENV_FILE@': unit_path(self.env_file)", "'@ENV_FILE@': unit_string(self.env_file)"),
            ('quoted WorkingDirectory scalar', "'@APP_ROOT@': unit_path(self.app)", "'@APP_ROOT@': unit_string(self.app)"),
            ('unquoted writable path list', "'@STATE_ROOT@': unit_string(self.var)", "'@STATE_ROOT@': unit_path(self.var)"),
            ('unquoted executable word', "'@APP_PYTHON@': unit_string(self.python)", "'@APP_PYTHON@': unit_path(self.python)"),
            ('unquoted server script word', "'@SERVER_SCRIPT@': unit_string(self.server)", "'@SERVER_SCRIPT@': unit_path(self.server)"),
            ('scalar specifier expansion', scalar, 'return str(value)'),
            ('whole scalar quoting', scalar, 'return unit_string(value)'),
            ('word-list specifier expansion', words, words.replace(".replace('%', '%%')", '')),
            ('word-list C escaping removed', words, "text = str(value).replace('%', '%%')"),
        )
        for label, before, after in edits:
            with self.subTest(case=label), fixture(native=True) as root:
                replace(root, controller, before, after)
                self.assert_rejected(root, label)

    def test_absolute_metadata_dispatch_and_stderr_only_failure_stay_root(self):
        for phase in PHASES:
            with self.subTest(phase=phase), fixture(native=True) as root:
                replace(root, 'cmd/' + phase, '/usr/bin/dirname', 'dirname')
                self.assert_rejected(root, 'metadata dispatcher inherits PATH: ' + phase)
        message = 'printf \'%s\\n\' "$message" >&2'
        edits = (
            ('foreign dirname utility', 'cmd/install_callback', '/usr/bin/dirname', '/bin/dirname'),
            ('dynamic dirname utility', 'cmd/install_callback', '/usr/bin/dirname', '"$DIRNAME"'),
            ('root temporary logfile redirect', 'cmd/main', message,
             message + '\n    printf \'%s\\n\' "$message" > "$TRIM_TEMP_LOGFILE"'),
            ('root protected-file redirect', 'cmd/main', message,
             'printf \'%s\\n\' "$message" > /etc/fnos-tripstar/fnos-tripstar.env'),
            ('root SDK failure command', 'cmd/main', message,
             message + '\n    /bin/sh -c "python backend/app/api/main.py"'),
        )
        for label, relative, before, after in edits:
            with self.subTest(case=label), fixture(native=True) as root:
                replace(root, relative, before, after)
                self.assert_rejected(root, label)

    def test_upgrade_compatibility_gate_is_current_or_one_exact_prior_phase(self):
        with fixture(native=True) as root:
            text = (root / 'cmd/main').read_text()
            source = (root / EVIDENCE['controller']).read_bytes()
            AUDIT._native_main(text, source)
            marker = 'exec "$PYTHON" -I -B - "$phase" <<\'PY\'\n'
            tree = AUDIT.ast.parse(text.split(marker, 1)[1][:-3])
            values = {node.targets[0].id: node.value for node in tree.body
                      if isinstance(node, AUDIT.ast.Assign)
                      and len(node.targets) == 1 and isinstance(node.targets[0], AUDIT.ast.Name)}
            current = AUDIT.ast.literal_eval(values['expected'])
            previous = AUDIT.ast.literal_eval(values['previous'])
            self.assertEqual(current, hashlib.sha256(source).hexdigest())
            self.assertEqual(previous, ('3be2bf491c90b0d175a87d8eac330d709970a590e20f85fc2a6c28305ae75ea2',
                                        '9e2e740c9fb53941b6fbb3374f7f35cdc5aeb9a625a40e4c49df9455e96fa2b0'))
            prior_expression = compile(AUDIT.ast.Expression(values['prior_upgrade']), '<prior-gate>', 'eval')
            rejection = next(node for node in tree.body if isinstance(node, AUDIT.ast.If))
            rejection_expression = compile(AUDIT.ast.Expression(rejection.test), '<pin-gate>', 'eval')
            phases = ('start', 'stop', 'status', 'install_callback', 'upgrade_init',
                      'upgrade_callback', 'uninstall_init')
            for digest in (current, *previous, '0' * 64):
                for phase in phases:
                    with self.subTest(digest=digest, phase=phase):
                        namespace = {'digest': digest, 'expected': current, 'previous': previous,
                                     'source': b'', 'sys': type('Phase', (), {'argv': ['controller', phase]})}
                        namespace['prior_upgrade'] = eval(prior_expression, {'__builtins__': {}}, namespace)
                        rejected = eval(rejection_expression, {'__builtins__': {'len': len}}, namespace)
                        allowed = digest == current or (digest in previous and phase == 'upgrade_init')
                        self.assertEqual(rejected, not allowed)
            namespace['source'] = b'x' * 131073
            namespace.update(digest=current, prior_upgrade=False)
            self.assertTrue(eval(rejection_expression, {'__builtins__': {'len': len}}, namespace))

    def test_prior_pin_sources_and_upgrade_gate_drift_stay_root(self):
        previous = ("previous = ('3be2bf491c90b0d175a87d8eac330d709970a590e20f85fc2a6c28305ae75ea2',\n"
                    "            '9e2e740c9fb53941b6fbb3374f7f35cdc5aeb9a625a40e4c49df9455e96fa2b0')")
        gate = "prior_upgrade = sys.argv[1] == 'upgrade_init' and digest in previous"
        check = 'digest != expected and not prior_upgrade'
        edits = (
            ('unknown historical pin', previous, "previous = '" + '0' * 64 + "'"),
            ('historical pin from environment', previous, "previous = os.environ['TRIM_PREVIOUS_SHA256']"),
            ('historical pin from install tree', previous, "previous = (Path(os.environ['TRIM_APPDEST']) / 'previous.sha256').read_text().strip()"),
            ('historical pin follows current value', previous, 'previous = expected'),
            ('historical pin overwritten', previous, previous + "\nprevious = '" + '0' * 64 + "'"),
            ('phase or checksum condition', gate, gate.replace(' and ', ' or ')),
            ('historical source accepts every phase', gate, 'prior_upgrade = digest in previous'),
            ('upgrade prefix matching', gate, "prior_upgrade = sys.argv[1].startswith('upgrade') and digest in previous"),
            ('historical callback enabled', gate, gate.replace("'upgrade_init'", "'upgrade_callback'")),
            ('historical start enabled', gate, gate.replace("'upgrade_init'", "'start'")),
            ('historical stop also enabled', gate, "prior_upgrade = sys.argv[1] in ('upgrade_init', 'stop') and digest in previous"),
            ('partial historical digest', gate, "prior_upgrade = sys.argv[1] == 'upgrade_init' and digest.startswith(previous[0][:8])"),
            ('upgrade accepts unknown digest', gate, "prior_upgrade = sys.argv[1] == 'upgrade_init'"),
            ('prior condition inverted', check, 'digest != expected and prior_upgrade'),
            ('prior exclusion removed', check, 'digest != expected'),
            ('checksum gate disabled', check, 'False'),
            ('source digest trusts expected pin', 'digest = hashlib.sha256(source).hexdigest()', 'digest = expected'),
        )
        for label, before, after in edits:
            with self.subTest(case=label), fixture(native=True) as root:
                replace(root, 'cmd/main', before, after)
                self.assert_rejected(root, label, repin=False)
        with fixture(native=True) as root:
            replace(root, 'cmd/main', previous, previous[:-1] + ", '" + '0' * 64 + "')")
            self.assert_rejected(root, 'historical allowlist extended', repin=False)

    def test_exec_service_type_required_guard_and_template_pin_drift_stay_root(self):
        for service_type in ('simple', 'idle', 'notify', 'forking'):
            with self.subTest(service_type=service_type), fixture(native=True) as root:
                unit(root, 'Type=exec', 'Type=' + service_type)
                self.assert_rejected(root, 'service type drift: ' + service_type)
        controller = EVIDENCE['controller']
        new_pin = "TEMPLATE_SHA256 = 'c5d2ea36996b323d43606eace7d947d1e4a924f3c2270ed273bebdee2c668435'"
        old_pin = "TEMPLATE_SHA256 = 'accb92a901596ddb3dfd155218b13ccf6eb6f7bf0b375d57af2588318d6a42f3'"
        edits = (
            ('required type removed', "required = ('Type=exec', ", 'required = ('),
            ('required type regressed to simple', "required = ('Type=exec', ", "required = ('Type=simple', "),
            ('old template pin on current source', new_pin, old_pin),
        )
        for label, before, after in edits:
            with self.subTest(case=label), fixture(native=True) as root:
                replace(root, controller, before, after)
                self.assert_rejected(root, label)
        with fixture(native=True) as root:
            unit(root, 'Type=exec', 'Type=simple')
            replace(root, controller, "required = ('Type=exec', ", "required = ('Type=simple', ")
            replace(root, controller, new_pin, old_pin)
            pin_controller(root)
            self.assert_rejected(root, 'old simple template and controller re-pinned together')

    def test_server_root_guard_and_top_level_execution_stay_root(self):
        server = 'app/bin/run-server.py'
        edits = (
            ('if os.geteuid() == 0:', 'if os.geteuid() != 0:'),
            ('if os.geteuid() == 0:', 'if False:'),
            ("raise RuntimeError('TripStar HTTP service must run as the package user, not root')", 'return'),
            ("raise RuntimeError('TripStar HTTP service must run as the package user, not root')",
             "raise RuntimeError(__import__('os').system('id'))"),
            ('def main():\n', 'def main():\n    import backend.app.api.main\n'),
            ('def main():\n', 'def main(default=__import__("os").system("id")):\n'),
            ('def main():\n', '@subprocess.run\ndef main():\n'),
            ('import os\n', 'import backend.app.api.main\nimport os\n'),
            ('import os\n', 'import os as other\n'),
            ("if __name__ == '__main__':\n    main()", 'main()'),
            ('import subprocess\n', 'import subprocess\nsubprocess.Popen(["python", "backend/app/api/main.py"])\n'),
        )
        for before, after in edits:
            with self.subTest(change=after), fixture(native=True) as root:
                replace(root, server, before, after)
                self.assert_rejected(root, after)

    def test_package_identity_and_privilege_overrides_stay_root(self):
        cases = (
            {'defaults': {'run-as': 'root'}, 'username': 'root', 'groupname': 'tripstar'},
            {'defaults': {'run-as': 'root'}, 'username': 'tripstar', 'groupname': 'root'},
            {'defaults': {'run-as': 'root'}, 'username': '$TRIM_USERNAME', 'groupname': 'tripstar'},
            {'defaults': {'run-as': 'root'}, 'username': '0', 'groupname': '0'},
            {'defaults': {'run-as': 'root'}, 'username': 'tripstar', 'groupname': 'tripstar',
             'run-as': {'start': 'root'}},
        )
        for value in cases:
            with self.subTest(privilege=value), fixture(native=True) as root:
                put(root, 'config/privilege', json.dumps(value))
                self.assert_rejected(root)
        with fixture(native=True) as root:
            put(root, 'config/privilege',
                '{"defaults":{"run-as":"root"},"username":"root","username":"tripstar","groupname":"tripstar"}')
            self.assert_rejected(root)


class ExistingAuditTests(unittest.TestCase):
    def codes(self, root):
        return {item['code'] for item in AUDIT.audit_project(root)['findings']}

    def test_package_and_ordinary_root_baselines_do_not_regress(self):
        with fixture() as root:
            self.assertEqual(AUDIT.audit_project(root)['summary']['total'], 0)
        for mode in ('root', 'ROOT'):
            with self.subTest(mode=mode), fixture(run_as=mode) as root:
                result = AUDIT.audit_project(root)
                self.assertEqual(result['summary']['total'], 1)
                self.assertEqual(result['findings'][0]['code'], 'ROOT_RUNTIME')
                self.assertEqual(result['findings'][0]['severity'], 'Medium')
        with fixture(run_as='root') as root:
            value = json.loads((root / 'app/ui/config').read_text())
            value['.url']['tripstar.main']['allUsers'] = True
            put(root, 'app/ui/config', json.dumps(value))
            self.assertEqual(self.codes(root), {'ROOT_RUNTIME', 'ROOT_ALL_USERS'})

    def test_manifest_and_entry_contracts_are_preserved(self):
        with fixture() as root:
            replace(root, 'manifest', 'platform=x86', 'platform=amd64')
            self.assertIn('MANIFEST_PLATFORM_INVALID', self.codes(root))
        with fixture() as root:
            value = json.loads((root / 'app/ui/config').read_text())
            value['.url']['tripstar.main'].update(port=17860, url='http://localhost:17860/')
            put(root, 'app/ui/config', json.dumps(value))
            self.assertEqual(self.codes(root), {'ENTRY_PORT_NOT_STRING', 'ENTRY_URL_FULL_LINK'})
        with fixture() as root:
            value = json.loads((root / 'app/ui/config').read_text())
            value['.url']['tripstar.main']['port'] = '17861'
            put(root, 'app/ui/config', json.dumps(value))
            self.assertIn('ENTRY_PORT_MISMATCH', self.codes(root))

    def test_openapi_scope_microapp_and_version_rules_are_preserved(self):
        with fixture() as root:
            put(root, 'app/frontend/index.js', "import { TrimApp } from '@trimjs/web-app';\ntrim.file.convertPath('path');\n")
            self.assertEqual(self.codes(root), {'OPENAPI_MICRO_APP_REQUIRED', 'OPENAPI_SCOPE_MISSING'})
            replace(root, 'manifest', 'os_min_version=1.2.0401', 'os_min_version=1.0.0\nmicro_app=true')
            put(root, 'config/resource', '{"api-scope":["trim.file.path"]}')
            self.assertEqual(self.codes(root), {'OPENAPI_VERSION_GATE'})
            replace(root, 'manifest', 'os_min_version=1.0.0', 'os_min_version=1.2.0401')
            self.assertEqual(self.codes(root), set())
        for value in ({'api-scope': 'trim.file.path'}, {'api-scope': [' ', 123]}):
            with self.subTest(scope=value), fixture() as root:
                put(root, 'config/resource', json.dumps(value))
                self.assertIn('OPENAPI_SCOPE_INVALID', self.codes(root))

    def test_openapi_token_and_authorization_rules_are_preserved(self):
        with fixture() as root:
            put(root, 'app/frontend/index.js', 'console.log(TRIM_API_TOKEN);\n')
            self.assertEqual(self.codes(root), {'OPENAPI_FRONTEND_BACKEND_API', 'OPENAPI_TOKEN_EXPOSURE'})
        with fixture() as root:
            put(root, 'app/backend/auth.py', 'output.write_text(TRIM_API_TOKEN)\n')
            self.assertIn('OPENAPI_TOKEN_EXPOSURE', self.codes(root))
        with fixture() as root:
            put(root, 'app/frontend/auth.js', "openAppAuth({redirect_uri: location.href});\nwindow.postMessage(payload, '*');\nwindow.addEventListener('message', handler);\n")
            self.assertEqual(self.codes(root), {'OPENAPI_AUTH_CALLBACK_REQUIRED', 'OPENAPI_MESSAGE_ORIGIN_REQUIRED'})

    def test_gateway_identity_and_theme_rules_are_preserved(self):
        with fixture() as root:
            value = json.loads((root / 'app/ui/config').read_text())
            value['.url']['tripstar.main']['gatewayPrefix'] = '/fixture'
            put(root, 'app/ui/config', json.dumps(value))
            put(root, 'app/backend/handler.js', 'const uid = req.body.uid;\n')
            self.assertIn('GATEWAY_CLIENT_IDENTITY_TRUST', self.codes(root))
        with fixture() as root:
            put(root, 'app/frontend/events.js', "sdk.$on('os/theme', handler);\n")
            self.assertIn('OPENAPI_HOST_EVENT_GUARD_REQUIRED', self.codes(root))

    def test_docker_image_and_lifecycle_rules_are_preserved(self):
        with fixture() as root:
            put(root, 'config/resource', '{"docker-project":{"projects":[{"name":"fixture","path":"docker"}]}}')
            put(root, 'app/docker/docker-compose.yaml', 'services:\n  main:\n    image: alpine:latest\n')
            self.assertEqual(self.codes(root), {'DOCKER_IMAGE_MUTABLE'})
            replace(root, 'app/docker/docker-compose.yaml', 'alpine:latest', 'alpine@sha256:' + 'a' * 64)
            self.assertEqual(self.codes(root), set())
            put(root, 'cmd/main', '#!/bin/sh\ncase "$1" in\nstart) docker compose up -d ;;\nstop) docker compose down ;;\nesac\n')
            self.assertIn('DOCKER_LIFECYCLE_CONFLICT', self.codes(root))

    def test_architecture_license_and_shell_rules_are_preserved(self):
        with fixture() as root:
            target = root / 'app/foreign-elf'
            target.write_bytes(b'\x7fELF\x02\x01' + bytes(12) + b'\x28\x00')
            self.assertIn('NATIVE_ARCH_MISMATCH', self.codes(root))
        with fixture() as root:
            (root / 'LICENSE').unlink()
            self.assertEqual(self.codes(root), {'LICENSE_EVIDENCE_MISSING'})
        with fixture() as root:
            put(root, 'cmd/main', '#!/bin/sh\neval "$phase"\nrun_hook 2>&1 | logger\n')
            self.assertEqual(self.codes(root), {'SHELL_EVAL', 'PIPELINE_STATUS_MASKED'})

    def test_cli_json_contract_and_nonzero_findings_are_not_filtered(self):
        for native in (False, True):
            with self.subTest(native=native), fixture(native=native, run_as='root') as root:
                command = ['bash', str(HERE / 'audit_fnos_project.sh'), '--project-path', str(root), '--format', 'json']
                completed = subprocess.run(command, capture_output=True, text=True, check=True)
                result = json.loads(completed.stdout)
                self.assertEqual(set(result), {'status', 'project', 'appname', 'summary', 'inventory', 'findings'})
                self.assertEqual(result['status'], 'completed')
                self.assertEqual(result['summary']['total'], 0 if native else 1)
                self.assertEqual(len(result['findings']), result['summary']['total'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
