#!/usr/bin/env python3
"""Isolated native probe and real unit-parser regressions; never control services."""
from contextlib import redirect_stdout
import errno
import io
import json
from pathlib import Path
import socket
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

import check_native_runtime as runtime
import native_checks as common
import native_preflight as preflight
from systemd_fields import unit_path, unit_word


class PreflightTests(unittest.TestCase):
    def test_python_isolated_abi_and_version(self):
        value = {'version': [3, 12, 4], 'machine': 'x86_64', 'bits': 64, 'ssl': 'OpenSSL fixture'}
        with mock.patch.object(preflight, 'executable', return_value=Path('/sdk/python')), \
                mock.patch.object(preflight, 'run', return_value=json.dumps(value)) as run:
            result = preflight.python_probe('/sdk/python', '3.12')
        self.assertFalse(result['site_packages_executed'])
        self.assertEqual(run.call_args.args[0][:4], ['/sdk/python', '-I', '-B', '-S'])

    def test_python_wrong_version(self):
        with mock.patch.object(preflight, 'executable', return_value=Path('/sdk/python')), \
                mock.patch.object(preflight, 'run', return_value='{"version":[3,11,9],"bits":64,"ssl":"x"}'):
            with self.assertRaises(common.CheckError):
                preflight.python_probe('/sdk/python', '3.12')

    def test_python_invalid_metadata(self):
        with mock.patch.object(preflight, 'executable', return_value=Path('/sdk/python')), \
                mock.patch.object(preflight, 'run', return_value='{"version":[true,12,4]}'):
            with self.assertRaises(common.CheckError):
                preflight.python_probe('/sdk/python', '3.12')

    def test_node_version(self):
        with mock.patch.object(preflight, 'executable', return_value=Path('/sdk/node')), \
                mock.patch.object(preflight, 'run', return_value='v22.18.0\n'):
            self.assertEqual(preflight.node_probe('/sdk/node', 22)['version'], 'v22.18.0')
            with self.assertRaises(common.CheckError):
                preflight.node_probe('/sdk/node', 20)

    def test_dedicated_group_not_primary(self):
        with mock.patch.object(preflight.pwd, 'getpwnam', return_value=SimpleNamespace(pw_uid=923, pw_gid=901)), \
                mock.patch.object(preflight.grp, 'getgrnam', return_value=SimpleNamespace(gr_gid=918)):
            result = preflight.identity_probe('tripstar', 'tripstar')
        self.assertEqual((result['primary_gid'], result['package_gid']), (901, 918))

    def test_root_identity_rejected(self):
        with mock.patch.object(preflight.pwd, 'getpwnam', return_value=SimpleNamespace(pw_uid=0, pw_gid=901)), \
                mock.patch.object(preflight.grp, 'getgrnam', return_value=SimpleNamespace(gr_gid=918)):
            with self.assertRaises(common.CheckError):
                preflight.identity_probe('root', 'tripstar')

    def test_registered_but_missing_sdk(self):
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaises(FileNotFoundError):
                common.executable(str(Path(temp) / 'missing'))

    def test_nonexecutable_sdk(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'python'
            path.write_text('fixture')
            path.chmod(0o600)
            with self.assertRaises(common.CheckError):
                common.executable(str(path))

    def test_busy_port_is_not_free(self):
        with socket.socket() as sock:
            sock.bind(('0.0.0.0', 0))
            sock.listen()
            self.assertFalse(common.port_free(sock.getsockname()[1]))

    def test_permission_error_is_not_port_occupancy(self):
        with mock.patch.object(common.socket, 'socket') as constructor:
            constructor.return_value.__enter__.return_value.bind.side_effect = OSError(errno.EACCES, 'fixture')
            with self.assertRaises(common.CheckError):
                common.port_free(17860)

    def test_fixed_environment_and_no_shell(self):
        with mock.patch.object(common.subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout='ok')) as call:
            self.assertEqual(common.run(['/sdk/node', '--version']), 'ok')
        self.assertEqual(call.call_args.kwargs['env'], common.ENV)
        self.assertNotIn('shell', call.call_args.kwargs)
        self.assertEqual(call.call_args.kwargs['cwd'], '/')

    def test_bad_arguments_are_json(self):
        stdout = io.StringIO()
        with redirect_stdout(stdout), self.assertRaises(SystemExit):
            preflight.main(['--port', '0'])
        self.assertFalse(json.loads(stdout.getvalue())['ok'])


class RuntimeTests(unittest.TestCase):
    def snapshot(self, **changes):
        value = {'LoadState': 'loaded', 'ActiveState': 'active', 'SubState': 'running',
                 'MainPID': '123', 'Type': 'exec', 'User': '923', 'Group': '918'}
        value.update(changes)
        return value

    def args(self, **changes):
        value = dict(unit='fixture.service', uid=923, gid=918, port=17860, state='running',
                     exe='/sdk/python', argv_token=['gunicorn'], health_url='http://127.0.0.1:17860/health',
                     health_key='status', health_value='healthy')
        value.update(changes)
        return SimpleNamespace(**value)

    def test_positive_unit_process_socket_health(self):
        with mock.patch.object(runtime, 'unit_snapshot', return_value=self.snapshot()), \
                mock.patch.object(runtime, 'process_probe', return_value={'pid': 123}), \
                mock.patch.object(runtime, 'socket_probe', return_value={'owner': 123}), \
                mock.patch.object(runtime, 'health_probe', return_value={'status': 'healthy'}):
            result = runtime.inspect(self.args())
        self.assertEqual(result['issues'], [])
        self.assertTrue(result['checks']['stable_unit_snapshot'])

    def test_start_record_is_not_running(self):
        with mock.patch.object(runtime, 'unit_snapshot', return_value=self.snapshot(ActiveState='activating', SubState='start')):
            self.assertTrue(runtime.inspect(self.args())['issues'])

    def test_simple_not_exec(self):
        with self.assertRaises(common.CheckError):
            runtime.metadata_identity(self.snapshot(Type='simple'), 923, 918)

    def test_primary_group_not_package_group(self):
        with self.assertRaises(common.CheckError):
            runtime.metadata_identity(self.snapshot(Group='901'), 923, 918)

    def test_pid_changes_during_snapshot(self):
        with mock.patch.object(runtime, 'unit_snapshot', side_effect=[self.snapshot(), self.snapshot(MainPID='124')]), \
                mock.patch.object(runtime, 'process_probe', return_value={}), \
                mock.patch.object(runtime, 'socket_probe', return_value={}), \
                mock.patch.object(runtime, 'health_probe', return_value={}):
            self.assertTrue(runtime.inspect(self.args())['issues'])

    def test_pid_reused_with_same_unit_snapshot(self):
        with mock.patch.object(runtime, 'unit_snapshot', return_value=self.snapshot()), \
                mock.patch.object(runtime, 'process_probe', side_effect=[{'pid': 123, 'start_time': 10}, {'pid': 123, 'start_time': 11}]), \
                mock.patch.object(runtime, 'socket_probe', return_value={}), \
                mock.patch.object(runtime, 'health_probe', return_value={}):
            self.assertTrue(runtime.inspect(self.args())['issues'])

    def test_stopped_pid_zero_port_free(self):
        with mock.patch.object(runtime, 'unit_snapshot', return_value=self.snapshot(ActiveState='inactive', SubState='dead', MainPID='0')), \
                mock.patch.object(runtime, 'port_free', return_value=True):
            self.assertEqual(runtime.inspect(self.args(state='stopped'))['issues'], [])

    def test_stopped_port_still_occupied(self):
        with mock.patch.object(runtime, 'unit_snapshot', return_value=self.snapshot(ActiveState='inactive', SubState='dead', MainPID='0')), \
                mock.patch.object(runtime, 'port_free', return_value=False):
            self.assertTrue(runtime.inspect(self.args(state='stopped'))['issues'])

    def test_failed_is_not_successfully_stopped(self):
        with mock.patch.object(runtime, 'unit_snapshot', return_value=self.snapshot(ActiveState='failed', SubState='failed', MainPID='0')):
            self.assertTrue(runtime.inspect(self.args(state='stopped'))['issues'])

    def test_pid_identity_all_four_fields(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            process = root / '123'
            process.mkdir()
            (process / 'status').write_text('Uid:\t923\t923\t923\t923\nGid:\t918\t918\t918\t918\n')
            (process / 'stat').write_text('123 (fixture) ' + ' '.join(['S'] + ['0'] * 18 + ['12345']))
            (process / 'cmdline').write_bytes(b'/sdk/python\0-m\0gunicorn\0')
            (process / 'exe').symlink_to('/sdk/python')
            result = runtime.process_probe(123, 923, 918, None, ['gunicorn'], root)
            self.assertEqual(result['uids'], [923] * 4)
            (process / 'status').write_text('Uid:\t923\t0\t923\t923\nGid:\t918\t918\t918\t918\n')
            with self.assertRaises(common.CheckError):
                runtime.process_probe(123, 923, 918, None, ['gunicorn'], root)

    def test_expected_argv_token_absent(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            process = root / '123'
            process.mkdir()
            (process / 'status').write_text('Uid:\t923\t923\t923\t923\nGid:\t918\t918\t918\t918\n')
            (process / 'stat').write_text('123 (fixture) ' + ' '.join(['S'] + ['0'] * 18 + ['12345']))
            (process / 'cmdline').write_bytes(b'/sdk/python\0-m\0wrong\0')
            (process / 'exe').symlink_to('/sdk/python')
            with self.assertRaises(common.CheckError):
                runtime.process_probe(123, 923, 918, None, ['gunicorn'], root)

    def test_listener_is_other_pid(self):
        with mock.patch.object(runtime, 'run', return_value='LISTEN 0 512 127.0.0.1:17860 *:* users:(("other",pid=456,fd=6))'):
            with self.assertRaises(common.CheckError):
                runtime.socket_probe(17860, 123)

    def test_listener_ownership_unavailable(self):
        with mock.patch.object(runtime, 'run', return_value='LISTEN 0 512 *:17860 *:*'):
            with self.assertRaises(common.CheckError):
                runtime.socket_probe(17860, 123)

    def test_master_and_worker_same_listener(self):
        with mock.patch.object(runtime, 'run', return_value='LISTEN 0 512 *:17860 *:* users:(("worker",pid=124,fd=6),("master",pid=123,fd=6))'):
            self.assertTrue(runtime.socket_probe(17860, 123)['main_pid_owns_listener'])

    def test_other_listener_same_port_different_address(self):
        value = 'LISTEN 0 512 10.0.0.1:17860 *:* users:(("master",pid=123,fd=6))\nLISTEN 0 512 127.0.0.1:17860 *:* users:(("other",pid=456,fd=6))'
        with mock.patch.object(runtime, 'run', return_value=value):
            with self.assertRaises(common.CheckError):
                runtime.socket_probe(17860, 123)

    def test_health_is_same_host_port(self):
        for url in ('http://example.com:17860/health', 'http://127.0.0.1:17861/health',
                    'http://user:pass@127.0.0.1:17860/health', 'http://127.0.0.1:17860/health?key=secret'):
            with self.subTest(url=url), self.assertRaises(common.CheckError):
                runtime.health_probe(url, 17860, 'status', 'healthy')

    def test_health_semantic_and_response_bound(self):
        with mock.patch.object(runtime.urllib.request, 'build_opener') as builder:
            response = builder.return_value.open.return_value.__enter__.return_value
            response.status = 200
            response.read.return_value = b'{"status":"healthy"}'
            self.assertEqual(runtime.health_probe('http://127.0.0.1:17860/health', 17860, 'status', 'healthy')['http_status'], 200)
            response.read.return_value = b'{"status":"starting"}'
            with self.assertRaises(common.CheckError):
                runtime.health_probe('http://127.0.0.1:17860/health', 17860, 'status', 'healthy')
            response.read.return_value = b'x' * 16385
            with self.assertRaises(common.CheckError):
                runtime.health_probe('http://127.0.0.1:17860/health', 17860, 'status', 'healthy')

    def test_redirect_is_not_evidence(self):
        with self.assertRaises(common.CheckError):
            runtime.NoRedirect().redirect_request(None, None, 302, 'fixture', None, 'http://example.com')


class UnitFieldTests(unittest.TestCase):
    def test_scalar_unquoted_words_quoted(self):
        path = '/tmp/with space/quote"/%/$literal'
        self.assertEqual(unit_path(path), '/tmp/with space/quote"/%%/$literal')
        self.assertEqual(unit_word(path), '"/tmp/with space/quote\\"/%%/$literal"')

    def test_reject_control_and_relative(self):
        for path in ('relative', '/tmp/inject\nUser=root', '/tmp/tab\t', '/tmp/trailing '):
            for helper in (unit_path, unit_word):
                with self.subTest(path=path), self.assertRaises(ValueError):
                    helper(path)

    @unittest.skipUnless(Path('/usr/bin/systemd-analyze').is_file(), 'Real unit parser is not installed')
    def test_template_actual_systemd_parser(self):
        root = Path(__file__).resolve().parents[1]
        template = (root / 'assets/native-exec.service.in').read_text()
        with tempfile.TemporaryDirectory(prefix='fnos-unit-') as temp:
            directory = Path(temp) / 'with space "quote" $dollar %percent'
            directory.mkdir()
            environment = directory / 'config.env'
            environment.write_text('FIXTURE=value\n')
            fields = {'@DESCRIPTION@': 'Native unit fixture', '@APP_USER@': 'nobody', '@APP_GROUP@': 'nogroup',
                      '@TARGET_PATH@': unit_path(directory), '@ROOT_ENV_PATH@': unit_path(environment),
                      '@PYTHON_WORD@': unit_word('/usr/bin/true'), '@SERVER_WORD@': unit_word('/usr/bin/true'),
                      '@STATE_WORDS@': unit_word(directory)}
            for token, value in fields.items():
                template = template.replace(token, value)
            unit = Path(temp) / 'fnos-fixture.service'
            unit.write_text(template)
            result = subprocess.run(['/usr/bin/systemd-analyze', 'verify', '--man=no', str(unit)],
                                    capture_output=True, text=True, env=common.ENV, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('Type=exec', template)
            self.assertIn('ExecStart=:', template)


if __name__ == '__main__':
    unittest.main(verbosity=2)
