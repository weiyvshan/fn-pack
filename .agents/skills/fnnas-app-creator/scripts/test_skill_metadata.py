#!/usr/bin/env python3
"""Isolated metadata fixtures; no application code or real services are run."""

import contextlib
import io
import json
import os
from pathlib import Path
from unittest.mock import patch
import tempfile
import unittest
import sys

sys.dont_write_bytecode = True
import validate_skill as validator


class SkillMetadataTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="skill-metadata-test-")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.root = self.base / "fixture-skill"
        self.root.mkdir()
        self.short = "Validate package metadata and references"
        self.body = "# Fixture skill\n\nRead [reference](references/guide.md).\nUse `scripts/tool.py` and `assets/icon.txt`.\n"
        self.front = "---\nname: 'fixture-skill'\ndescription: 'A fixture for skill validation.'\n---\n"
        self.agent = (
            "interface:\n"
            "  display_name: 'Fixture Skill'\n"
            "  short_description: '" + self.short + "'\n"
            "  default_prompt: 'Use $fixture-skill to inspect this fixture.'\n"
        )
        self.seed()

    def put(self, relative, content):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content.encode("utf-8") if isinstance(content, str) else content)
        return path

    def seed(self):
        self.put("SKILL.md", self.front + self.body)
        self.put("agents/openai.yaml", self.agent)
        self.put("references/guide.md", "# Guide\nRead [entry](../SKILL.md#fixture).\n")
        self.put("scripts/tool.py", "raise RuntimeError('never execute a referenced script')\n")
        self.put("scripts/tool.sh", "exit 99\n")
        self.put("assets/icon.txt", "fixture asset\n")

    def report(self):
        return validator.validate_skill(self.root)

    def assert_code(self, report, code):
        self.assertEqual(report["status"], "error")
        self.assertIn(code, [issue["code"] for issue in report["issues"]])

    def cli(self, arguments):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = validator.main(arguments)
        return status, json.loads(output.getvalue())

    def test_valid_skill_and_resource_references(self):
        report = self.report()
        self.assertEqual(report["status"], "ok", report)
        self.assertEqual(report["name"], "fixture-skill")
        self.assertEqual(report["body_lines"], 4)
        self.assertGreaterEqual(report["references_checked"], 4)

    def test_double_quotes_single_quote_escaping_and_comments(self):
        self.put("SKILL.md", "---\nname: \"fixture-skill\" # name\ndescription: 'It''s a fixture.' # description\n---\n# Body\n")
        self.put("agents/openai.yaml", "interface:\n  display_name: \"Fixture \\\"Skill\\\"\"\n  short_description: \"" + self.short + "\"\n  default_prompt: \"Use $fixture-skill now.\"\n")
        self.assertEqual(self.report()["status"], "ok")

    def test_official_plain_name_and_plain_description_are_supported(self):
        self.put("SKILL.md", "---\nname: fixture-skill # official skeleton\ndescription: Ordinary plain text description\n---\n" + self.body)
        self.assertEqual(self.report()["status"], "ok")

    def test_description_has_no_mandatory_trigger_words(self):
        self.put("SKILL.md", self.front.replace("A fixture for skill validation.", "x") + self.body)
        self.assertEqual(self.report()["status"], "ok")

    def test_empty_or_missing_description(self):
        for front in (self.front.replace("A fixture for skill validation.", ""),
                      self.front.replace("description: 'A fixture for skill validation.'\n", "")):
            with self.subTest(front=front):
                self.put("SKILL.md", front + self.body)
                self.assert_code(self.report(), "DESCRIPTION_MISSING")

    def test_description_limit(self):
        self.put("SKILL.md", self.front.replace("A fixture for skill validation.", "x" * 1024) + self.body)
        self.assertEqual(self.report()["status"], "ok")
        self.put("SKILL.md", self.front.replace("A fixture for skill validation.", "x" * 1025) + self.body)
        self.assert_code(self.report(), "DESCRIPTION_LENGTH")

    def test_name_mismatch(self):
        self.put("SKILL.md", self.front.replace("fixture-skill", "other-skill") + self.body)
        self.assert_code(self.report(), "NAME_MISMATCH")

    def test_name_empty_missing_numeric_and_bad_case(self):
        for value, code in (("''", "NAME_MISSING"), ("42", "FRONTMATTER_STRING"),
                            ("'42'", "NAME_MISMATCH"), ("'Fixture-Skill'", "NAME_FORMAT"),
                            ("'bad--name'", "NAME_FORMAT"), ("'-bad'", "NAME_FORMAT"),
                            ("'bad-'", "NAME_FORMAT"), ("'bad_name'", "NAME_FORMAT")):
            with self.subTest(value=value):
                self.put("SKILL.md", self.front.replace("'fixture-skill'", value) + self.body)
                self.assert_code(self.report(), code)
        self.put("SKILL.md", self.front.replace("name: 'fixture-skill'\n", "") + self.body)
        self.assert_code(self.report(), "NAME_MISSING")

    def test_name_length_limit(self):
        self.put("SKILL.md", self.front.replace("fixture-skill", "x" * 65) + self.body)
        self.assert_code(self.report(), "NAME_FORMAT")

    def test_directory_name_is_validated(self):
        renamed = self.base / "Bad_Name"
        self.root.rename(renamed)
        self.assert_code(validator.validate_skill(renamed), "DIRECTORY_NAME")

    def test_frontmatter_duplicate_keys(self):
        for extra in ("name: 'fixture-skill'\n", "description: 'duplicate'\n"):
            with self.subTest(extra=extra):
                self.put("SKILL.md", self.front.replace("\n---\n", "\n" + extra + "---\n") + self.body)
                self.assert_code(self.report(), "FRONTMATTER_DUPLICATE")

    def test_missing_and_unclosed_frontmatter(self):
        self.put("SKILL.md", self.body)
        self.assert_code(self.report(), "FRONTMATTER_MISSING")
        self.put("SKILL.md", "---\nname: 'fixture-skill'\ndescription: 'fixture'\n")
        self.assert_code(self.report(), "FRONTMATTER_UNCLOSED")

    def test_frontmatter_non_string_and_dynamic_yaml_forms(self):
        for value in ("true", "false", "yes", "null", "~", "123", "1.5", "1e5", "0xff", ".nan", "1:30", "[one, two]", "{key: value}", "|", "!tag 'text'", "&anchor value"):
            with self.subTest(value=value):
                self.put("SKILL.md", self.front.replace("'A fixture for skill validation.'", value) + self.body)
                self.assert_code(self.report(), "FRONTMATTER_STRING")

    def test_unclosed_quoted_scalar_and_trailing_data(self):
        for value in ("'unclosed", '"unclosed', "'text' unexpected", '"text" unexpected'):
            with self.subTest(value=value):
                self.put("SKILL.md", self.front.replace("'A fixture for skill validation.'", value) + self.body)
                self.assert_code(self.report(), "FRONTMATTER_STRING")

    def test_body_line_boundaries(self):
        self.put("SKILL.md", self.front + "Body line\n" * 500)
        self.assertEqual(self.report()["status"], "ok")
        self.put("SKILL.md", self.front + "Body line\n" * 501)
        self.assert_code(self.report(), "BODY_LENGTH")

    def test_unfinished_placeholder_markers(self):
        for marker in ("TODO", "todo", "TBD", "FIXME", "[PLACEHOLDER]"):
            with self.subTest(marker=marker):
                self.put("SKILL.md", self.front + self.body + marker + "\n")
                self.assert_code(self.report(), "PLACEHOLDER")

    def test_missing_skill_and_agent_files(self):
        (self.root / "SKILL.md").unlink()
        self.assert_code(self.report(), "SKILL_READ")
        self.seed()
        (self.root / "agents/openai.yaml").unlink()
        self.assert_code(self.report(), "AGENT_READ")

    def test_agent_required_fields(self):
        for key in ("display_name", "short_description", "default_prompt"):
            with self.subTest(key=key):
                lines = [line for line in self.agent.splitlines() if not line.strip().startswith(key + ":")]
                self.put("agents/openai.yaml", "\n".join(lines) + "\n")
                self.assert_code(self.report(), "AGENT_REQUIRED")

    def test_short_description_boundaries(self):
        for size, status in ((24, "error"), (25, "ok"), (64, "ok"), (65, "error")):
            with self.subTest(size=size):
                self.put("agents/openai.yaml", self.agent.replace(self.short, "x" * size))
                report = self.report()
                self.assertEqual(report["status"], status)
                if status == "error":
                    self.assert_code(report, "SHORT_DESCRIPTION_LENGTH")

    def test_default_prompt_exact_skill_reference(self):
        for replacement in ("fixture-skill", "$other-skill", "$fixture-skill-extra"):
            with self.subTest(replacement=replacement):
                self.put("agents/openai.yaml", self.agent.replace("$fixture-skill", replacement))
                self.assert_code(self.report(), "PROMPT_SKILL")

    def test_agent_unquoted_or_non_string_fields(self):
        for value in ("Fixture Skill", "42", "true", "null", "['value']"):
            with self.subTest(value=value):
                self.put("agents/openai.yaml", self.agent.replace("'Fixture Skill'", value))
                self.assert_code(self.report(), "AGENT_STRING")

    def test_agent_duplicate_field_and_section(self):
        self.put("agents/openai.yaml", self.agent + "  display_name: 'duplicate'\n")
        self.assert_code(self.report(), "AGENT_DUPLICATE")
        self.put("agents/openai.yaml", self.agent + "interface:\n")
        self.assert_code(self.report(), "AGENT_DUPLICATE")

    def test_agent_missing_interface_or_wrong_indentation(self):
        self.put("agents/openai.yaml", self.agent.replace("interface:", "other:"))
        self.assert_code(self.report(), "AGENT_INTERFACE")
        self.put("agents/openai.yaml", self.agent.replace("  display_name:", "    display_name:"))
        self.assert_code(self.report(), "AGENT_FORMAT")
        self.put("agents/openai.yaml", self.agent.replace("  display_name:", "\tdisplay_name:"))
        self.assert_code(self.report(), "AGENT_FORMAT")

    def test_optional_metadata_sections_do_not_need_yaml_dependency(self):
        self.put("agents/openai.yaml", self.agent + "policy:\n  allow_implicit_invocation: true\n")
        self.assertEqual(self.report()["status"], "ok")

    def test_broken_relative_markdown_link(self):
        self.put("SKILL.md", self.front + self.body + "[missing](references/missing.md)\n")
        self.assert_code(self.report(), "REFERENCE_MISSING")

    def test_reference_document_relative_resolution(self):
        self.put("references/guide.md", "[script](../scripts/tool.py)\n[asset](../assets/icon.txt)\n")
        self.assertEqual(self.report()["status"], "ok")
        self.put("references/guide.md", "[missing](../scripts/missing.py)\n")
        self.assert_code(self.report(), "REFERENCE_MISSING")

    def test_reference_style_links_and_images(self):
        self.put("references/guide.md", "[image]: ../assets/icon.txt\n![image](../assets/icon.txt)\n[bad]: missing.md\n")
        self.assert_code(self.report(), "REFERENCE_MISSING")

    def test_fragment_and_external_links_are_not_fetched(self):
        self.put("references/guide.md", "[anchor](#heading)\n[web](https://invalid.invalid/no-request#anchor)\n[web2](http://invalid.invalid)\n")
        self.assertEqual(self.report()["status"], "ok")

    def test_parent_and_absolute_reference_escape(self):
        outside = self.base / "outside.md"
        outside.write_text("outside fixture", encoding="utf-8")
        for target in ("../outside.md", str(outside), "file:///etc/passwd", "//server/share"):
            with self.subTest(target=target):
                self.put("SKILL.md", self.front + self.body + "[outside](" + target + ")\n")
                self.assert_code(self.report(), "REFERENCE_ESCAPE")

    def test_symlink_reference_escape(self):
        outside = self.base / "outside.md"
        outside.write_text("outside fixture", encoding="utf-8")
        (self.root / "references/link.md").symlink_to(outside)
        self.put("SKILL.md", self.front + self.body + "[outside](references/link.md)\n")
        report = self.report()
        self.assert_code(report, "REFERENCE_ESCAPE")
        self.assert_code(report, "REFERENCE_READ")

    def test_skill_file_symlink_is_not_followed(self):
        original = self.root / "SKILL.md"
        original.rename(self.root / "copy.md")
        original.symlink_to(self.root / "copy.md")
        self.assert_code(self.report(), "SKILL_READ")

    def test_reference_directory_symlink_is_not_walked(self):
        outside = self.base / "external"
        outside.mkdir()
        (self.root / "references/link-dir").symlink_to(outside, target_is_directory=True)
        self.assert_code(self.report(), "REFERENCE_SYMLINK")

    def test_inline_script_and_asset_paths_must_exist(self):
        for path in ("scripts/missing.py", "scripts/missing.sh", "assets/missing.png"):
            with self.subTest(path=path):
                self.put("SKILL.md", self.front + self.body + "Run `python3 " + path + " --help`.\n")
                self.assert_code(self.report(), "REFERENCE_MISSING")

    def test_plain_text_and_fenced_code_resource_references(self):
        for body in ("Run scripts/missing.py next.\n", "```bash\npython3 scripts/missing.py --help\n```\n"):
            with self.subTest(body=body):
                self.put("SKILL.md", self.front + body)
                self.assert_code(self.report(), "REFERENCE_MISSING")
        self.put("SKILL.md", self.front + "```bash\npython3 scripts/tool.py --help\n```\n")
        self.assertEqual(self.report()["status"], "ok")

    def test_execute_only_parent_does_not_require_directory_listing(self):
        old_mode = self.base.stat().st_mode & 0o7777
        self.base.chmod(0o111)
        try:
            self.assertEqual(self.report()["status"], "ok")
        finally:
            self.base.chmod(old_mode)

    def test_directory_descriptors_use_path_only(self):
        original_open = os.open
        flags_seen = []

        def opening(path, flags, *args, **kwargs):
            flags_seen.append(flags)
            return original_open(path, flags, *args, **kwargs)

        with patch.object(validator.os, "open", side_effect=opening):
            self.assertEqual(self.report()["status"], "ok")
        directory_flags = [flags for flags in flags_seen if flags & os.O_DIRECTORY]
        self.assertTrue(directory_flags)
        self.assertTrue(all(flags & os.O_PATH and flags & os.O_NOFOLLOW for flags in directory_flags))

    def test_agents_parent_symlink_is_not_followed(self):
        original = self.root / "agents"
        original.rename(self.root / "agent-copy")
        original.symlink_to(self.root / "agent-copy", target_is_directory=True)
        self.assert_code(self.report(), "AGENT_READ")

    def test_resource_script_directory_is_not_a_regular_script(self):
        (self.root / "scripts/tool.py").unlink()
        (self.root / "scripts/tool.py").mkdir()
        self.assert_code(self.report(), "REFERENCE_TYPE")

    def test_referenced_scripts_are_never_executed(self):
        marker = self.base / "execution-marker"
        self.put("scripts/tool.py", "from pathlib import Path\nPath(" + repr(str(marker)) + ").write_text('executed')\n")
        self.assertEqual(self.report()["status"], "ok")
        self.assertFalse(marker.exists())

    def test_binary_and_unrelated_trees_are_not_traversed(self):
        self.put("bin/unrelated.md", "[must not be checked](missing.md)\n")
        self.put("assets/unrelated.bin", b"\xff\xfe\x00")
        if hasattr(os, "mkfifo"):
            os.mkfifo(self.root / "bin/fifo")
        self.assertEqual(self.report()["status"], "ok")

    def test_text_limits_and_invalid_utf8(self):
        self.put("SKILL.md", b"x" * (validator.MAX_TEXT_BYTES + 1))
        self.assert_code(self.report(), "SKILL_READ")
        self.seed()
        self.put("references/guide.md", b"\xff")
        self.assert_code(self.report(), "REFERENCE_READ")

    def test_checker_does_not_rewrite_metadata(self):
        paths = [self.root / "SKILL.md", self.root / "agents/openai.yaml", self.root / "references/guide.md"]
        before = [(path.read_bytes(), path.stat().st_mtime_ns, path.stat().st_mode) for path in paths]
        self.assertEqual(self.report()["status"], "ok")
        after = [(path.read_bytes(), path.stat().st_mtime_ns, path.stat().st_mode) for path in paths]
        self.assertEqual(before, after)

    def test_missing_or_non_directory_skill(self):
        self.assert_code(validator.validate_skill(self.base / "missing"), "SKILL_DIRECTORY")
        self.assert_code(validator.validate_skill(self.root / "SKILL.md"), "SKILL_DIRECTORY")

    def test_cli_json_exit_codes_and_help(self):
        status, report = self.cli([str(self.root)])
        self.assertEqual((status, report["status"]), (0, "ok"))
        for arguments in ([], ["--unknown"], [str(self.root), "extra"]):
            with self.subTest(arguments=arguments):
                status, report = self.cli(arguments)
                self.assertEqual((status, report["status"]), (1, "error"))
        status, report = self.cli(["--help"])
        self.assertEqual(status, 0)
        self.assertEqual(report["usage"], "validate_skill.py SKILL_DIR")


def main():
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(SkillMetadataTests)
    result = unittest.TestResult()
    suite.run(result)
    report = {"status": "ok" if result.wasSuccessful() else "error", "tests": result.testsRun,
              "failures": len(result.failures), "errors": len(result.errors), "skipped": len(result.skipped),
              "details": [{"test": str(test), "trace": trace} for test, trace in result.failures + result.errors]}
    print(json.dumps(report, ensure_ascii=True, sort_keys=True))
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
