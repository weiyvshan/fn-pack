#!/usr/bin/env python3
"""Linux-only offline lifecycle tests. NSS is mocked, never modified.

Optional real native smoke: V2RAYA_SMOKE_ROOT=/absolute/preflight-app python3 -B ...
Run as an existing nonroot identity. No user creation, SDK links or host changes.
"""
import importlib.util
import json
import os
from pathlib import Path
import socket
import stat
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('control', Path(__file__).resolve().parents[1] / 'cmd/control.py')
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)


class ControlTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='v2raya-test-')
        self.base = Path(self.temp.name)
        self.etc = self.base / 'etc'
        self.etc.mkdir(mode=0o700)
        self.root = self.base / 'target'
        self.root.mkdir()

    def tearDown(self):
        self.temp.cleanup()

    def test_identity_rejects_root(self):
        with patch.object(c.pwd, 'getpwnam', return_value=types.SimpleNamespace(pw_uid=123)), patch.object(c.grp, 'getgrnam', return_value=types.SimpleNamespace(gr_gid=456)), patch.object(c.os, 'geteuid', return_value=0):
            with self.assertRaisesRegex(RuntimeError, 'nonroot'):
                c.identity()

    def test_identity_dedicated_not_primary_group(self):
        with patch.object(c.pwd, 'getpwnam', return_value=types.SimpleNamespace(pw_uid=123, pw_gid=999)), patch.object(c.grp, 'getgrnam', return_value=types.SimpleNamespace(gr_gid=456)), patch.object(c.os, 'geteuid', return_value=123), patch.object(c.os, 'getegid', return_value=456), patch.dict(os.environ, {'TRIM_UID': '123', 'TRIM_GID': '456'}):
            self.assertEqual(c.identity(), (123, 456))
            with patch.dict(os.environ, {'TRIM_GID': '999'}):
                with self.assertRaisesRegex(RuntimeError, 'UID/GID'):
                    c.identity()

    def test_group_reexec_is_fixed(self):
        with patch.object(c.pwd, 'getpwnam', return_value=types.SimpleNamespace(pw_uid=123)), patch.object(c.grp, 'getgrnam', return_value=types.SimpleNamespace(gr_gid=456)), patch.object(c.os, 'geteuid', return_value=123), patch.object(c.os, 'getegid', return_value=999), patch.dict(os.environ, {'TRIM_UID': '123', 'TRIM_GID': '456', '_V2RAYA_GROUP_REEXEC': '0'}), patch.object(c.os, 'execv', side_effect=RuntimeError('reexec')) as execute:
            with self.assertRaisesRegex(RuntimeError, 'reexec'):
                c.identity()
            self.assertEqual(execute.call_args.args[0], '/usr/bin/sg')
            self.assertIn(c.PYTHON + ' -I -B', execute.call_args.args[1][-1])

    def test_credentials_bytes_and_controls(self):
        with patch.dict(os.environ, {'wizard_v2raya_username': 'admin', 'wizard_v2raya_password': '中' * 4}):
            self.assertEqual(c.credentials()['password'], '中' * 4)
        for value in ('short', 'x' * 33, '中' * 11, 'a' * 12 + '\n'):
            with patch.dict(os.environ, {'wizard_v2raya_username': 'admin', 'wizard_v2raya_password': value}):
                with self.assertRaises(RuntimeError):
                    c.credentials()

    def test_unknown_database_fails_closed(self):
        self.assertFalse(c.initialized(self.etc))
        (self.etc / 'v2raya.db').write_bytes(b'unknown')
        with self.assertRaisesRegex(RuntimeError, 'unknown administrator'):
            c.initialized(self.etc)

    def test_marker_preserved_and_requires_database(self):
        marker = self.etc / c.MARKER
        marker.write_text('{"schema":1,"application":"v2raya"}\n')
        marker.chmod(0o600)
        with self.assertRaises(RuntimeError):
            c.initialized(self.etc)
        (self.etc / 'v2raya.db').write_bytes(b'database')
        self.assertTrue(c.initialized(self.etc))
        marker.chmod(0o644)
        with self.assertRaises(RuntimeError):
            c.initialized(self.etc)

    def test_process_discrimination(self):
        args = c.argv_for(self.root, self.etc)
        good = {'uid': [123] * 4, 'gid': [456] * 4, 'argv': list(map(os.fsencode, args)),
                'exe': args[0], 'stamp': '42', 'group': 321, 'parent': 1}
        with patch.object(c, 'snapshot', return_value=good):
            self.assertEqual(c.process(321, self.root, self.etc, 123, 456)['kind'], 'service')
        for key, value in [('uid', [0] * 4), ('gid', [999] * 4), ('exe', '/other/v2raya'), ('argv', good['argv'] + [b'--reset-password'])]:
            with patch.object(c, 'snapshot', return_value=dict(good, **{key: value})):
                self.assertIsNone(c.process(321, self.root, self.etc, 123, 456))
        core = [str(self.root / 'bin/v2raya_core'), 'run', '--config=' + str(self.etc / 'config.json')]
        with patch.object(c, 'snapshot', return_value=dict(good, exe=core[0], argv=list(map(os.fsencode, core)))):
            self.assertEqual(c.process(321, self.root, self.etc, 123, 456)['kind'], 'core')

    def test_pid_reuse_never_signaled(self):
        expected = {'uid': [123]*4, 'gid': [456]*4, 'argv': [b'a'], 'exe': 'a', 'stamp': '42', 'group': 123}
        with patch.object(c.os, 'pidfd_open', return_value=99), patch.object(c.os, 'close'), patch.object(c, 'snapshot', return_value=dict(expected, stamp='43')), patch.object(c.signal, 'pidfd_send_signal') as kill:
            c.signal_exact(123, expected, c.signal.SIGTERM)
            kill.assert_not_called()

    def test_stop_rejects_unknown_group_member_without_signaling(self):
        proc = self.base / 'proc'
        proc.mkdir()
        (proc / '11').mkdir()
        (proc / '12').mkdir()
        service = {'kind': 'service', 'group': 11, 'stamp': '42'}
        foreign = {'uid': [123]*4, 'gid': [456]*4, 'group': 11, 'exe': '/bin/sleep', 'argv': [b'sleep', b'999']}
        with patch.object(c, 'PROC', proc), patch.object(c, 'owned', return_value={11: service}), patch.object(c, 'snapshot', return_value=foreign), patch.object(c, 'signal_exact') as kill:
            with self.assertRaisesRegex(RuntimeError, 'unverified process-group'):
                c.stop(self.root, self.etc, self.base, 123, 456)
            kill.assert_not_called()

    def test_stop_discovers_service_and_orphan_core_without_pid_file(self):
        proc = self.base / 'proc'
        proc.mkdir()
        service = {'kind': 'service', 'group': 11, 'stamp': '42'}
        core = {'kind': 'core', 'group': 22, 'stamp': '43'}
        with patch.object(c, 'PROC', proc), patch.object(c, 'owned', side_effect=[{11: service, 22: core}, {}]), patch.object(c, 'snapshot', return_value=None), patch.object(c, 'listening', return_value=False), patch.object(c, 'signal_exact') as kill:
            c.stop(self.root, self.etc, self.base, 123, 456)
            self.assertEqual([call.args[0] for call in kill.call_args_list], [11, 22])

    def test_bootstrap_preserves_original_failure_when_cleanup_fails(self):
        child = types.SimpleNamespace(wait=lambda timeout: None)
        with patch.object(c, 'preflight'), patch.object(c, 'initialized', return_value=True), patch.object(c, 'owned', return_value={}), patch.object(c, 'spawn', return_value=child), patch.object(c, 'ready', side_effect=subprocess.CalledProcessError(17, 'v2raya')), patch.object(c, 'stop', side_effect=RuntimeError('cleanup')):
            with self.assertRaises(subprocess.CalledProcessError) as caught:
                c.prepare(self.root, self.etc, self.base, self.base, 123, 456, self.base / 'socket')
            self.assertEqual(caught.exception.returncode, 17)

    def test_health_checks_all_fields(self):
        data = {'version': c.VERSION, 'lite': 1, 'isRoot': False, 'variant': 'V2rayaCore', 'serviceValid': True, 'coreVersionValid': True, 'coreVersion': c.VERSION, 'hasAccounts': True}
        with patch.object(c, 'api', return_value=data):
            self.assertTrue(c.health())
        for key in data:
            with patch.object(c, 'api', return_value=dict(data, **{key: None})):
                self.assertFalse(c.health())
        with patch.object(c, 'api', return_value=dict(data, lite=True)):
            self.assertFalse(c.health())

    def test_phase_dispatch_without_target(self):
        for phase in ('install_init', 'config_init', 'uninstall_callback'):
            with patch.object(c, 'identity', return_value=(123, 456)), patch.object(sys, 'argv', ['control.py', phase]), patch.object(c, 'path', side_effect=AssertionError('target accessed')):
                self.assertEqual(c.main(), 0)
        with patch.object(c, 'identity', return_value=(123, 456)), patch.object(sys, 'argv', ['control.py', 'arbitrary']):
            with self.assertRaisesRegex(RuntimeError, 'unsupported'):
                c.main()

    def test_failure_report_is_secret_free(self):
        log = self.base / 'failure.log'
        log.touch()
        with patch.dict(os.environ, {'TRIM_TEMP_LOGFILE': str(log)}), patch.object(c.os, 'geteuid', return_value=123):
            c.report(ValueError('super-secret-password'))
        self.assertIn('inspection failed', log.read_text())
        self.assertNotIn('super-secret', log.read_text())

    def test_offline_assets_required(self):
        with self.assertRaises(RuntimeError):
            c.preflight(self.root)
        for name in ('bin/v2raya', 'bin/v2raya_core', 'share/geoip.dat', 'share/geosite.dat'):
            file = self.root / name
            file.parent.mkdir(exist_ok=True)
            file.write_bytes(b'asset')
            file.chmod(0o700)
        c.preflight(self.root)
        (self.root / 'share/geoip.dat').write_bytes(b'')
        with self.assertRaises(RuntimeError):
            c.preflight(self.root)

    def test_argv_socket_and_environment(self):
        sock = self.base / 'bootstrap.sock'
        args = c.argv_for(self.root, self.etc, sock)
        self.assertIn('--address=127.0.0.1:2017', args)
        self.assertIn('--socket=' + str(sock), args)
        self.assertNotIn('--socket=', ' '.join(c.argv_for(self.root, self.etc)))
        self.assertNotIn('ipforward', c.DEFAULTS)

    def test_existing_bootstrap_never_creates_or_resets_account(self):
        calls = []
        def api(route, method='GET', body=None, token=None, sock=None):
            calls.append((route, method))
            return {'hasAnyAccounts': True}
        child = types.SimpleNamespace(wait=lambda timeout: None)
        with patch.object(c, 'preflight'), patch.object(c, 'initialized', return_value=True), patch.object(c, 'credentials', side_effect=AssertionError('secret read')), patch.object(c, 'owned', return_value={}), patch.object(c, 'spawn', return_value=child), patch.object(c, 'ready'), patch.object(c, 'api', side_effect=api), patch.object(c, 'health', return_value=True), patch.object(c, 'stop'):
            c.prepare(self.root, self.etc, self.base, self.base, 123, 456, self.base / 'socket')
        self.assertEqual(calls, [('account', 'GET'), ('account', 'GET')])


@unittest.skipUnless(os.environ.get('V2RAYA_SMOKE_ROOT'), 'set V2RAYA_SMOKE_ROOT for verified native smoke')
class NativeSmoke(unittest.TestCase):
    def test_fresh_reinstall_upgrade_missing_pid_and_cold_start(self):
        self.assertNotEqual(os.geteuid(), 0, 'smoke must run as existing nonroot user')
        root = Path(os.environ['V2RAYA_SMOKE_ROOT']).resolve(strict=True)
        uid, gid = os.geteuid(), os.getegid()
        with tempfile.TemporaryDirectory(prefix='v2raya-') as temporary:
            base = Path(temporary)
            env = {'TRIM_APPDEST': str(root), 'TRIM_UID': str(uid), 'TRIM_GID': str(gid),
                   'wizard_v2raya_username': 'smoke-admin', 'wizard_v2raya_password': 'smoke-only-Password-42'}
            for key, name in [('TRIM_PKGETC','etc'), ('TRIM_PKGVAR','var'), ('TRIM_PKGTMP','tmp'), ('TRIM_PKGHOME','home')]:
                folder = base / name
                folder.mkdir(mode=0o700)
                env[key] = str(folder)
            def phase(name):
                with patch.object(sys, 'argv', ['control.py', name]):
                    return c.main()
            spawned = []
            original_spawn = c.spawn
            def tracked_spawn(*args, **kwargs):
                child = original_spawn(*args, **kwargs)
                spawned.append(child)
                return child
            with patch.dict(os.environ, env), patch.object(c.pwd, 'getpwnam', return_value=types.SimpleNamespace(pw_uid=uid, pw_gid=gid)), patch.object(c.grp, 'getgrnam', return_value=types.SimpleNamespace(gr_gid=gid)), patch.object(c, 'spawn', side_effect=tracked_spawn):
                try:
                    self.assertEqual(phase('install_init'), 0)
                    self.assertEqual(phase('install_callback'), 0)
                    self.assertFalse(c.listening())
                    marker = base / 'etc/v2raya' / c.MARKER
                    self.assertEqual(stat.S_IMODE(marker.stat().st_mode), 0o600)
                    self.assertEqual(phase('start'), 0)
                    self.assertEqual(phase('status'), 0)
                    token = c.api('login', 'POST', {'username': env['wizard_v2raya_username'], 'password': env['wizard_v2raya_password']})['token']
                    self.assertTrue(token)
                    settings = c.api('setting', token=token)['setting']
                    self.assertTrue(all(settings[k] == v for k, v in c.DEFAULTS.items()))
                    # A real standalone core with the exact package config
                    # models an orphan after service death. No proxy traffic.
                    config = base / 'etc/v2raya/config.json'
                    config.write_text(json.dumps({'log': {'loglevel': 'none'}, 'outbounds': [{'protocol': 'freedom', 'tag': 'direct'}]}))
                    core_args = [str(root / 'bin/v2raya_core'), 'run', '--config=' + str(config)]
                    core = subprocess.Popen(core_args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
                    try:
                        self.assertTrue(c.wait_until(lambda: c.process(core.pid, root, config.parent, uid, gid) is not None, 5))
                        (base / 'var/run/v2raya.pid.json').unlink()
                        self.assertEqual(phase('upgrade_init'), 0)
                    finally:
                        phase('stop')
                        core.wait(timeout=5)
                    self.assertIsNotNone(core.returncode)
                    self.assertEqual(phase('status'), 3)
                    # Reinstall and upgrades never require or overwrite credentials.
                    os.environ['wizard_v2raya_password'] = 'invalid-new-password'
                    self.assertEqual(phase('upgrade_callback'), 0)
                    self.assertEqual(phase('install_callback'), 0)
                    self.assertEqual(phase('start'), 0)
                    self.assertTrue(c.api('login', 'POST', {'username': env['wizard_v2raya_username'], 'password': env['wizard_v2raya_password']})['token'])
                    self.assertEqual(phase('uninstall_init'), 0)
                    self.assertTrue(marker.is_file())
                    self.assertEqual(phase('uninstall_callback'), 0)
                finally:
                    phase('stop')
                    for child in spawned:
                        child.wait(timeout=5)


if __name__ == '__main__':
    unittest.main(verbosity=2)
