#!/usr/bin/env python3
"""Isolated fixtures for the read-only content pin checker."""

import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import sys

sys.dont_write_bytecode = True
import check_content_pins as checker


class ContentPinTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="content-pins-test-")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.root = self.base / "project"
        self.root.mkdir()
        self.edges = [
            ("cmd/main", "expected", "app/bin/lifecycle.py"),
            ("app/bin/lifecycle.py", "TEMPLATE_SHA256", "app/systemd/service.in"),
            ("app/bin/lifecycle.py", "SETUP_SHA256", "app/bin/setup.py"),
        ]
        self.seed()

    def put(self, relative, content):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content.encode("utf-8") if isinstance(content, str) else content)
        return path

    def digest(self, relative):
        return hashlib.sha256((self.root / relative).read_bytes()).hexdigest()

    def seed(self):
        self.put("app/systemd/service.in", "[Service]\nType=exec\nUser=fixture\n")
        self.put("app/bin/setup.py", "# isolated setup; never imported\n")
        self.lifecycle = (
            "TEMPLATE_SHA256 = '" + self.digest("app/systemd/service.in") + "'\n" +
            "SETUP_SHA256 = '" + self.digest("app/bin/setup.py") + "'\n"
        )
        self.put("app/bin/lifecycle.py", self.lifecycle)
        self.repinned_main()

    def repinned_main(self):
        self.main = "#!/bin/sh\npython3 - <<'PY'\nexpected = '" + self.digest("app/bin/lifecycle.py") + "'\nPY\n"
        self.put("cmd/main", self.main)

    def result(self, edges=None, limit=checker.DEFAULT_MAX_BYTES):
        return checker.check_project(self.root, self.edges if edges is None else edges, limit)

    def assert_code(self, report, code):
        self.assertEqual(report["status"], "error")
        self.assertIn(code, [item["code"] for item in report["issues"]])

    def cli(self, arguments):
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            status = checker.main(arguments)
        return status, json.loads(buffer.getvalue())

    def test_matching_three_edge_chain(self):
        report = self.result()
        self.assertEqual(report["status"], "ok")
        self.assertEqual(len(report["edges"]), 3)
        for row in report["edges"]:
            self.assertTrue(row["matches"])
            self.assertEqual(row["expected_sha256"], row["actual_sha256"])
        self.assertIn("do not exempt", report["notice"])

    def test_each_asset_drift(self):
        for index, (_, _, asset) in enumerate(self.edges):
            with self.subTest(edge=index):
                self.seed()
                path = self.root / asset
                path.write_bytes(path.read_bytes() + b"\n# changed\n")
                report = self.result()
                self.assert_code(report, "PIN_DRIFT")
                self.assertIn(index, [issue["edge"] for issue in report["issues"] if issue["code"] == "PIN_DRIFT"])

    def test_duplicate_python_assignment(self):
        self.put("app/bin/lifecycle.py", self.lifecycle + self.lifecycle.splitlines()[0] + "\n")
        self.assert_code(self.result(), "PIN_DUPLICATE")

    def test_duplicate_shell_assignment(self):
        self.put("cmd/main", self.main + "expected = '" + "0" * 64 + "'\n")
        self.assert_code(self.result(), "PIN_DUPLICATE")

    def test_python_dynamic_assignment_is_not_run(self):
        marker = self.base / "dynamic-marker"
        self.put("app/bin/lifecycle.py", "TEMPLATE_SHA256 = open(" + repr(str(marker)) + ", 'w').write('executed')\n")
        self.assert_code(self.result(), "PIN_NONLITERAL")
        self.assertFalse(marker.exists())

    def test_shell_dynamic_assignment_is_not_run(self):
        marker = self.base / "shell-marker"
        self.put("cmd/main", "expected = $(touch " + str(marker) + ")\n")
        self.assert_code(self.result(), "PIN_NONLITERAL")
        self.assertFalse(marker.exists())

    def test_application_source_is_never_executed_or_imported(self):
        marker = self.base / "application-marker"
        source = "from pathlib import Path\nPath(" + repr(str(marker)) + ").write_text('executed')\nraise RuntimeError('fixture')\n"
        self.put("app/bin/lifecycle.py", self.lifecycle + source)
        self.put("app/bin/setup.py", source)
        setup_sha = self.digest("app/bin/setup.py")
        self.put("app/bin/lifecycle.py", self.lifecycle.replace(self.digest_from_text("# isolated setup; never imported\n"), setup_sha) + source)
        self.repinned_main()
        self.assertEqual(self.result()["status"], "ok")
        self.assertFalse(marker.exists())

    @staticmethod
    def digest_from_text(text):
        return hashlib.sha256(text.encode("utf-8")).hexdigest()

    def test_invalid_sha_is_not_disclosed(self):
        secret = "SECRET_FIXTURE_VALUE_NEVER_PRINT"
        self.put("cmd/main", "expected = '" + secret + "'\n")
        report = self.result()
        self.assert_code(report, "PIN_SHA")
        self.assertNotIn(secret, json.dumps(report))

    def test_missing_pin_assignment(self):
        self.put("cmd/main", "# expected = '" + "0" * 64 + "'\n")
        self.assert_code(self.result(), "PIN_MISSING")

    def test_nested_assignment_is_not_a_top_level_pin(self):
        self.put("holder.py", "def function():\n    PIN = '" + "0" * 64 + "'\n")
        self.assert_code(self.result([("holder.py", "PIN", "app/bin/setup.py")]), "PIN_NONLITERAL")

    def test_chained_assignment_is_not_a_simple_pin(self):
        self.put("holder.py", "OTHER = PIN = '" + "0" * 64 + "'\n")
        self.assert_code(self.result([("holder.py", "PIN", "app/bin/setup.py")]), "PIN_NONLITERAL")

    def test_pin_rebinding_import_and_mutation_fail(self):
        for suffix in ("\nPIN += '0'\n", "\nfrom other import PIN\n", "\ndef PIN():\n    pass\n", "\ndel PIN\n"):
            with self.subTest(suffix=suffix):
                self.put("holder.py", "PIN = '" + "0" * 64 + "'\n" + suffix)
                self.assert_code(self.result([("holder.py", "PIN", "app/bin/setup.py")]), "PIN_DUPLICATE")

    def test_utf8_and_python_syntax_errors_do_not_disclose_source(self):
        self.put("holder.py", b"\xff")
        self.assert_code(self.result([("holder.py", "PIN", "app/bin/setup.py")]), "HOLDER_ENCODING")
        secret = "SECRET_SYNTAX_MARKER"
        self.put("holder.py", "PIN = (" + secret + "\n")
        report = self.result([("holder.py", "PIN", "app/bin/setup.py")])
        self.assert_code(report, "HOLDER_SYNTAX")
        self.assertNotIn(secret, json.dumps(report))

    def test_uppercase_literal_and_annotation(self):
        self.put("holder.py", "PIN: str = '" + self.digest("app/bin/setup.py").upper() + "'\n")
        self.assertEqual(self.result([("holder.py", "PIN", "app/bin/setup.py")])["status"], "ok")

    def test_holder_oversize(self):
        self.put("cmd/main", self.main + "#" * 200)
        self.assert_code(self.result(limit=150), "OVERSIZE")

    def test_asset_exact_limit_and_one_byte_over(self):
        self.put("asset", b"x" * 128)
        self.put("holder", "PIN = '" + self.digest("asset") + "'\n")
        edge = [("holder", "PIN", "asset")]
        self.assertEqual(self.result(edge, 128)["status"], "ok")
        self.put("asset", b"x" * 129)
        self.assert_code(self.result(edge, 128), "OVERSIZE")

    def test_maximum_limit_specification(self):
        for limit in (0, -1, checker.HARD_MAX_BYTES + 1, "131072", True):
            with self.subTest(limit=limit):
                self.assert_code(self.result(limit=limit), "MAX_BYTES")

    def test_asset_symlink_inside_and_outside_project(self):
        for destination in (self.root / "app/bin/setup.py", self.base / "outside"):
            with self.subTest(destination=str(destination)):
                if destination == self.base / "outside":
                    destination.write_text("outside secret", encoding="utf-8")
                link = self.root / "linked"
                link.symlink_to(destination)
                self.assert_code(self.result([("cmd/main", "expected", "linked")]), "SYMLINK")
                link.unlink()

    def test_holder_symlink(self):
        self.put("actual-holder", self.main)
        (self.root / "linked-holder").symlink_to(self.root / "actual-holder")
        self.assert_code(self.result([("linked-holder", "expected", "app/bin/lifecycle.py")]), "SYMLINK")

    def test_parent_directory_symlink(self):
        outside = self.base / "outside"
        outside.mkdir()
        (outside / "asset").write_text("fixture", encoding="utf-8")
        (self.root / "link-dir").symlink_to(outside, target_is_directory=True)
        self.assert_code(self.result([("cmd/main", "expected", "link-dir/asset")]), "SYMLINK")

    @unittest.skipUnless(hasattr(os, "mkfifo"), "FIFO is unavailable")
    def test_fifo_holder_and_asset_are_rejected_without_blocking(self):
        os.mkfifo(self.root / "fifo")
        for spec in (("cmd/main", "expected", "fifo"), ("fifo", "expected", "app/bin/setup.py")):
            with self.subTest(spec=spec):
                self.assert_code(self.result([spec]), "NOT_REGULAR")

    def test_directory_is_not_a_regular_asset(self):
        self.assert_code(self.result([("cmd/main", "expected", "app/bin")]), "NOT_REGULAR")

    def test_missing_file(self):
        self.assert_code(self.result([("cmd/main", "expected", "missing")]), "MISSING_FILE")

    def test_path_boundary_and_malformed_paths(self):
        for value, code in (("../outside", "PATH_ESCAPE"), (str(self.base / "outside"), "PATH_ESCAPE"),
                            ("app/../asset", "PATH_ESCAPE"), ("./asset", "PATH_SPEC"),
                            ("app//asset", "PATH_SPEC"), ("", "PATH_SPEC"),
                            ("app\\asset", "PATH_SPEC"), ("asset\x00", "PATH_SPEC")):
            with self.subTest(path=value):
                self.assert_code(self.result([("cmd/main", "expected", value)]), code)

    def test_malformed_edges_and_constant_names(self):
        for spec, code in ((["cmd/main", "expected"], "EDGE_SPEC"), ("invalid", "EDGE_SPEC"),
                           (("cmd/main", "expected;raise", "app/bin/setup.py"), "CONSTANT_SPEC"),
                           (("cmd/main", "", "app/bin/setup.py"), "CONSTANT_SPEC")):
            with self.subTest(spec=spec):
                self.assert_code(self.result([spec]), code)
        self.assert_code(self.result([]), "EDGE_SPEC")

    def test_installed_project_guard_without_reading_installed_files(self):
        for root in ("/vol1/@appcenter/demo", "/var/packages/demo/target", "/var/apps/demo/target"):
            with self.subTest(root=root):
                with patch.object(checker.Path, "resolve", return_value=Path(root)), patch.object(checker, "open_root") as opening:
                    report = checker.check_project(self.root, self.edges)
                self.assert_code(report, "INSTALLED_PROJECT")
                opening.assert_not_called()

    def test_changed_file_is_rejected(self):
        self.put("asset", "original")
        self.put("holder", "PIN = '" + self.digest("asset") + "'\n")
        original_read = os.read
        changed = False

        def reading(descriptor, count):
            nonlocal changed
            data = original_read(descriptor, count)
            if not changed and data == b"original":
                changed = True
                self.put("asset", "changed content")
            return data

        with patch.object(checker.os, "read", side_effect=reading):
            self.assert_code(self.result([("holder", "PIN", "asset")]), "FILE_CHANGED")

    def test_execute_only_parent_does_not_require_directory_listing(self):
        old_mode = self.base.stat().st_mode & 0o7777
        self.base.chmod(0o111)
        try:
            self.assertEqual(self.result()["status"], "ok")
        finally:
            self.base.chmod(old_mode)

    def test_directory_descriptors_use_path_only_and_final_reads_are_nonblocking(self):
        original_open = os.open
        calls = []

        def opening(path, flags, *args, **kwargs):
            calls.append(flags)
            return original_open(path, flags, *args, **kwargs)

        with patch.object(checker.os, "open", side_effect=opening):
            self.assertEqual(self.result()["status"], "ok")
        directory_flags = [flags for flags in calls if flags & os.O_DIRECTORY]
        file_flags = [flags for flags in calls if not flags & os.O_DIRECTORY]
        self.assertTrue(directory_flags)
        self.assertTrue(file_flags)
        self.assertTrue(all(flags & os.O_PATH and flags & os.O_NOFOLLOW for flags in directory_flags))
        self.assertTrue(all(flags & os.O_NONBLOCK and flags & os.O_NOFOLLOW for flags in file_flags))

    def test_checker_does_not_rewrite_source_or_pins(self):
        paths = [self.root / path for path in {edge[0] for edge in self.edges} | {edge[2] for edge in self.edges}]
        before = [(path.read_bytes(), path.stat().st_mtime_ns, path.stat().st_mode) for path in paths]
        self.assertEqual(self.result()["status"], "ok")
        after = [(path.read_bytes(), path.stat().st_mtime_ns, path.stat().st_mode) for path in paths]
        self.assertEqual(before, after)

    def test_cli_json_and_exit_codes(self):
        arguments = ["--project-path", str(self.root)]
        for edge in self.edges:
            arguments.extend(["--edge", *edge])
        status, report = self.cli(arguments)
        self.assertEqual((status, report["status"]), (0, "ok"))
        for invalid in ([], ["--edge", "a", "b"], ["--max-bytes", "no"], ["--unknown"]):
            with self.subTest(arguments=invalid):
                status, report = self.cli(invalid)
                self.assertEqual((status, report["status"]), (1, "error"))
        status, report = self.cli(["--help"])
        self.assertEqual(status, 0)
        self.assertIn("--edge HOLDER CONSTANT ASSET", report["usage"])


def main():
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(ContentPinTests)
    result = unittest.TestResult()
    suite.run(result)
    report = {"status": "ok" if result.wasSuccessful() else "error", "tests": result.testsRun,
              "failures": len(result.failures), "errors": len(result.errors), "skipped": len(result.skipped),
              "details": [{"test": str(test), "trace": trace} for test, trace in result.failures + result.errors]}
    print(json.dumps(report, ensure_ascii=True, sort_keys=True))
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
