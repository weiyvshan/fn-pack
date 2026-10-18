#!/usr/bin/env python3
"""Validate skill metadata and local references without third-party YAML code."""

import argparse
import json
import os
from pathlib import Path
import re
import stat
import sys
from urllib.parse import unquote, urlsplit

MAX_TEXT_BYTES = 1048576
NAME_PATTERN = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*\Z")
KEY_PATTERN = re.compile(r"([A-Za-z_][A-Za-z0-9_-]*)\s*:\s*(.*)\Z")
PLACEHOLDER_PATTERN = re.compile(r"\b(?:TODO|TBD|FIXME)\b|\[\s*PLACEHOLDER\s*\]", re.IGNORECASE)
LINK_PATTERN = re.compile(r"!?\[[^\]\n]*\]\(\s*(<[^>\n]+>|[^\s)]+)(?:\s+(?:\"[^\"]*\"|'[^']*'))?\s*\)")
DEFINITION_PATTERN = re.compile(r"^[ \t]{0,3}\[[^\]\n]+\]:\s*(<[^>\n]+>|\S+)", re.MULTILINE)
SCRIPT_PATTERN = re.compile(r"(?<![A-Za-z0-9_./-])(?:\./)?scripts/[A-Za-z0-9_./-]+\.(?:py|sh)(?![A-Za-z0-9_.-])")
ASSET_PATTERN = re.compile(r"(?<![A-Za-z0-9_./-])(?:\./)?assets/[^\s`\"'<>()[\]{}]+")


class MetadataError(Exception):
    pass


class JsonParser(argparse.ArgumentParser):
    def error(self, message):
        raise MetadataError("Invalid command arguments; use --help for the interface.")


def quoted_scalar(value):
    value = value.strip()
    if not value or value[0] not in ("'", '"'):
        raise MetadataError("A quoted inline string is required.")
    if value[0] == '"':
        try:
            decoded, end = json.JSONDecoder().raw_decode(value)
        except (ValueError, RecursionError):
            raise MetadataError("Invalid double-quoted inline string.") from None
        tail = value[end:].strip()
        if not isinstance(decoded, str) or (tail and not tail.startswith("#")):
            raise MetadataError("A single quoted inline string is required.")
        return decoded
    chars = []
    position = 1
    while position < len(value):
        if value[position] == "'":
            if position + 1 < len(value) and value[position + 1] == "'":
                chars.append("'")
                position += 2
                continue
            tail = value[position + 1:].strip()
            if tail and not tail.startswith("#"):
                raise MetadataError("Unexpected data after the single-quoted string.")
            return "".join(chars)
        chars.append(value[position])
        position += 1
    raise MetadataError("Unclosed single-quoted inline string.")


def frontmatter_scalar(value):
    value = value.strip()
    if value.startswith(("'", '"')):
        return quoted_scalar(value)
    value = re.sub(r"\s+#.*$", "", value).strip()
    reserved = {"true", "false", "yes", "no", "on", "off", "null", "~"}
    numeric = re.compile(r"[+-]?(?:0[xob][0-9a-f_]+|[0-9][0-9_]*(?:\.[0-9_]*)?(?:e[+-]?[0-9_]+)?|\.[0-9_]+(?:e[+-]?[0-9_]+)?|\.(?:inf|nan)|[0-9_]+(?::[0-9_]+)+(?:\.[0-9_]*)?)\Z", re.IGNORECASE)
    if (not value or value.lower() in reserved or numeric.fullmatch(value) or
            value.startswith(("[", "{", "&", "*", "!", "|", ">", "#", "%", "- ", "? ")) or
            re.search(r":\s", value) or re.fullmatch(r"\d{4}-\d{1,2}-\d{1,2}(?:[tT ].*)?", value)):
        raise MetadataError("A quoted or ordinary plain inline string is required.")
    return value


def add_issue(report, code, message, file=None, line=None):
    issue = {"code": code, "message": message}
    if file is not None:
        issue["file"] = file
    if line is not None:
        issue["line"] = line
    report["issues"].append(issue)


def contained(root, path):
    try:
        return path.resolve(strict=False).is_relative_to(root)
    except (OSError, ValueError, RuntimeError):
        return False


def bounded_text(root, path):
    if not contained(root, path):
        raise MetadataError("The text file resolves outside the skill directory.")
    descriptor = None
    directory = None
    try:
        relative = path.relative_to(root)
        if not all(hasattr(os, flag) for flag in ("O_PATH", "O_DIRECTORY", "O_NOFOLLOW", "O_NONBLOCK")):
            raise MetadataError("Linux descriptor-bound no-follow reads are required.")
        directory = os.open(root.anchor, os.O_PATH | os.O_DIRECTORY | os.O_NOFOLLOW |
                            getattr(os, "O_CLOEXEC", 0))
        if not stat.S_ISDIR(os.fstat(directory).st_mode):
            raise MetadataError("The root anchor is not a directory.")
        for part in root.parts[1:] + relative.parts[:-1]:
            following = os.open(part, os.O_PATH | os.O_DIRECTORY | os.O_NOFOLLOW |
                                getattr(os, "O_CLOEXEC", 0), dir_fd=directory)
            if not stat.S_ISDIR(os.fstat(following).st_mode):
                os.close(following)
                raise MetadataError("An opened ancestor is not a directory.")
            os.close(directory)
            directory = following
        descriptor = os.open(relative.parts[-1], os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW |
                             getattr(os, "O_CLOEXEC", 0), dir_fd=directory)
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode):
            raise MetadataError("The text file must be a regular non-symlink file.")
        if info.st_size > MAX_TEXT_BYTES:
            raise MetadataError("The text file exceeds the fixed byte limit.")
        data = bytearray()
        while len(data) <= MAX_TEXT_BYTES:
            block = os.read(descriptor, min(65536, MAX_TEXT_BYTES + 1 - len(data)))
            if not block:
                break
            data.extend(block)
        if len(data) > MAX_TEXT_BYTES:
            raise MetadataError("The bounded text read exceeded the fixed byte limit.")
        after = os.fstat(descriptor)
        if (info.st_size, info.st_mtime_ns, info.st_ctime_ns) != (
                after.st_size, after.st_mtime_ns, after.st_ctime_ns):
            raise MetadataError("The text file changed during the read.")
        try:
            return data.decode("utf-8")
        except UnicodeDecodeError:
            raise MetadataError("The text file is not UTF-8.") from None
    finally:
        if descriptor is not None:
            os.close(descriptor)
        if directory is not None:
            os.close(directory)


def frontmatter(report, text):
    lines = text.splitlines()
    if not lines or lines[0] != "---":
        add_issue(report, "FRONTMATTER_MISSING", "SKILL.md must start with a frontmatter delimiter.", "SKILL.md", 1)
        return {}, lines
    closing = next((index for index in range(1, len(lines)) if lines[index] == "---"), None)
    if closing is None:
        add_issue(report, "FRONTMATTER_UNCLOSED", "The frontmatter closing delimiter is missing.", "SKILL.md")
        return {}, []
    result = {}
    seen = set()
    for index, line in enumerate(lines[1:closing], 2):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if line != line.lstrip() or KEY_PATTERN.fullmatch(line) is None:
            add_issue(report, "FRONTMATTER_FORMAT", "Frontmatter requires flat key/value entries.", "SKILL.md", index)
            continue
        key, raw = KEY_PATTERN.fullmatch(line).groups()
        if key in seen:
            add_issue(report, "FRONTMATTER_DUPLICATE", "A frontmatter key is repeated.", "SKILL.md", index)
            continue
        seen.add(key)
        try:
            result[key] = frontmatter_scalar(raw)
        except MetadataError:
            add_issue(report, "FRONTMATTER_STRING", "Frontmatter values must be quoted or ordinary plain inline strings.", "SKILL.md", index)
    return result, lines[closing + 1:]


def interface_metadata(report, text):
    result = {}
    root_keys = set()
    interface_keys = set()
    section = None
    for index, line in enumerate(text.splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if "\t" in line[:len(line) - len(line.lstrip())]:
            add_issue(report, "AGENT_FORMAT", "Tabs are not supported for metadata indentation.", "agents/openai.yaml", index)
            continue
        indentation = len(line) - len(line.lstrip(" "))
        match = KEY_PATTERN.fullmatch(line.strip())
        if match is None:
            add_issue(report, "AGENT_FORMAT", "Metadata requires mapping entries.", "agents/openai.yaml", index)
            continue
        key, raw = match.groups()
        if indentation == 0:
            if key in root_keys:
                add_issue(report, "AGENT_DUPLICATE", "A metadata section is repeated.", "agents/openai.yaml", index)
            root_keys.add(key)
            section = key
            if key == "interface" and raw and not raw.startswith("#"):
                add_issue(report, "AGENT_FORMAT", "interface must be a mapping section.", "agents/openai.yaml", index)
            continue
        if section != "interface":
            continue
        if indentation != 2:
            add_issue(report, "AGENT_FORMAT", "Interface fields must use two-space indentation.", "agents/openai.yaml", index)
            continue
        if key in interface_keys:
            add_issue(report, "AGENT_DUPLICATE", "An interface field is repeated.", "agents/openai.yaml", index)
            continue
        interface_keys.add(key)
        try:
            result[key] = quoted_scalar(raw)
        except MetadataError:
            add_issue(report, "AGENT_STRING", "Interface fields must be quoted inline strings.", "agents/openai.yaml", index)
    if "interface" not in root_keys:
        add_issue(report, "AGENT_INTERFACE", "The interface metadata mapping is missing.", "agents/openai.yaml")
    return result


def check_reference(report, root, source, target, seen, resource=False):
    target = target.strip("<>")
    if not target or target.startswith("#"):
        return
    try:
        parsed = urlsplit(target)
    except ValueError:
        add_issue(report, "REFERENCE_FORMAT", "The reference URL or path is malformed.", source.relative_to(root).as_posix())
        return
    if parsed.scheme in ("http", "https", "mailto"):
        return
    source_label = source.relative_to(root).as_posix()
    if parsed.scheme or parsed.netloc:
        add_issue(report, "REFERENCE_ESCAPE", "A local reference must not use a filesystem URI or external authority.", source_label)
        return
    key = (source_label, target, resource)
    if key in seen:
        return
    seen.add(key)
    report["references_checked"] += 1
    try:
        raw_path = unquote(parsed.path, errors="strict")
        if "\x00" in raw_path or "\\" in raw_path:
            raise ValueError
        base = root if resource else source.parent
        path = base / raw_path
    except (ValueError, UnicodeError):
        add_issue(report, "REFERENCE_FORMAT", "The local reference path is malformed.", source_label)
        return
    if not contained(root, path):
        add_issue(report, "REFERENCE_ESCAPE", "A local reference resolves outside the skill directory.", source_label)
    elif not path.exists():
        add_issue(report, "REFERENCE_MISSING", "A local reference does not exist: " + raw_path, source_label)
    elif ((resource and raw_path.startswith(("scripts/", "./scripts/"))) or
          path.suffix.lower() == ".md") and not path.is_file():
        add_issue(report, "REFERENCE_TYPE", "A script or Markdown reference must be a regular file.", source_label)


def check_markdown(report, root, source, text, seen):
    masked = list(text)
    for pattern in (LINK_PATTERN, DEFINITION_PATTERN):
        for match in pattern.finditer(text):
            check_reference(report, root, source, match.group(1), seen)
            masked[match.start():match.end()] = " " * (match.end() - match.start())
    resource_text = "".join(masked)
    for pattern in (SCRIPT_PATTERN, ASSET_PATTERN):
        for reference in pattern.finditer(resource_text):
            target = reference.group(0).rstrip(",;")
            if not any(mark in target for mark in ("*", "$", "...")):
                check_reference(report, root, source, target, seen, resource=True)


def validate_skill(skill_dir):
    report = {"status": "error", "skill_dir": str(skill_dir), "issues": [],
              "body_lines": 0, "references_checked": 0}
    try:
        root = Path(skill_dir).resolve(strict=True)
        if not root.is_dir():
            raise MetadataError("The skill path must be a directory.")
    except (OSError, ValueError, RuntimeError, MetadataError):
        add_issue(report, "SKILL_DIRECTORY", "The skill directory is missing or invalid.")
        return report
    report["skill_dir"] = str(root)
    if len(root.name) > 64 or NAME_PATTERN.fullmatch(root.name) is None:
        add_issue(report, "DIRECTORY_NAME", "The directory name must be hyphen-case and at most 64 characters.")
    skill = root / "SKILL.md"
    texts = []
    try:
        text = bounded_text(root, skill)
        metadata, body = frontmatter(report, text)
        report["body_lines"] = len(body)
        name = metadata.get("name")
        if name is None or not name.strip():
            add_issue(report, "NAME_MISSING", "A nonempty quoted name is required.", "SKILL.md")
        elif len(name) > 64 or NAME_PATTERN.fullmatch(name) is None:
            add_issue(report, "NAME_FORMAT", "The skill name must be hyphen-case and at most 64 characters.", "SKILL.md")
        elif name != root.name:
            add_issue(report, "NAME_MISMATCH", "The skill name must exactly match its directory name.", "SKILL.md")
        else:
            report["name"] = name
        description = metadata.get("description")
        if description is None or not description.strip():
            add_issue(report, "DESCRIPTION_MISSING", "A nonempty quoted description is required.", "SKILL.md")
        elif len(description) > 1024:
            add_issue(report, "DESCRIPTION_LENGTH", "The description exceeds 1024 characters.", "SKILL.md")
        if len(body) > 500:
            add_issue(report, "BODY_LENGTH", "The skill body exceeds 500 lines.", "SKILL.md")
        if PLACEHOLDER_PATTERN.search(text):
            add_issue(report, "PLACEHOLDER", "The skill contains an unfinished placeholder marker.", "SKILL.md")
        texts.append((skill, text))
    except (OSError, ValueError, RuntimeError, MetadataError):
        add_issue(report, "SKILL_READ", "SKILL.md is missing, unreadable, unsafe, or oversized.", "SKILL.md")
    agent_path = root / "agents/openai.yaml"
    try:
        interface = interface_metadata(report, bounded_text(root, agent_path))
        for key in ("display_name", "short_description", "default_prompt"):
            if not interface.get(key, "").strip():
                add_issue(report, "AGENT_REQUIRED", "A nonempty quoted " + key + " is required.", "agents/openai.yaml")
        short = interface.get("short_description")
        if short is not None and not 25 <= len(short) <= 64:
            add_issue(report, "SHORT_DESCRIPTION_LENGTH", "short_description must contain 25 to 64 characters.", "agents/openai.yaml")
        prompt = interface.get("default_prompt", "")
        if re.search(re.escape("$" + root.name) + r"(?![a-z0-9-])", prompt) is None:
            add_issue(report, "PROMPT_SKILL", "default_prompt must contain the exact $skill-name reference.", "agents/openai.yaml")
    except (OSError, ValueError, RuntimeError, MetadataError):
        add_issue(report, "AGENT_READ", "agents/openai.yaml is missing, unreadable, unsafe, or oversized.", "agents/openai.yaml")
    references = root / "references"
    if references.exists():
        if not contained(root, references) or references.is_symlink():
            add_issue(report, "REFERENCE_ESCAPE", "The references directory must stay within the skill.", "references")
        elif references.is_dir():
            def walk_error(error):
                add_issue(report, "REFERENCE_READ", "The reference directory could not be listed.", "references")

            for directory, children, files in os.walk(references, followlinks=False, onerror=walk_error):
                parent = Path(directory)
                for child in list(children):
                    if (parent / child).is_symlink():
                        children.remove(child)
                        add_issue(report, "REFERENCE_SYMLINK", "Reference subdirectories must not be symlinks.",
                                  (parent / child).relative_to(root).as_posix())
                for filename in sorted(files):
                    if not filename.lower().endswith(".md"):
                        continue
                    source = parent / filename
                    try:
                        texts.append((source, bounded_text(root, source)))
                    except (OSError, ValueError, RuntimeError, MetadataError):
                        add_issue(report, "REFERENCE_READ", "A Markdown reference is unreadable, unsafe, or oversized.",
                                  source.relative_to(root).as_posix())
        else:
            add_issue(report, "REFERENCE_DIRECTORY", "references must be a directory when present.", "references")
    seen = set()
    for source, text in texts:
        check_markdown(report, root, source, text, seen)
    report["status"] = "ok" if not report["issues"] else "error"
    return report


def main(argv=None):
    parser = JsonParser(add_help=False)
    parser.add_argument("--help", action="store_true")
    parser.add_argument("skill_dir", nargs="?")
    try:
        args = parser.parse_args(argv)
        if args.help:
            report = {"status": "ok", "usage": "validate_skill.py SKILL_DIR",
                      "frontmatter": "Flat quoted or ordinary plain inline strings; name and description required.",
                      "body_line_limit": 500, "description_character_limit": 1024,
                      "short_description_character_range": [25, 64]}
        elif args.skill_dir is None:
            raise MetadataError("The positional skill directory is required.")
        else:
            report = validate_skill(args.skill_dir)
    except MetadataError:
        report = {"status": "error", "issues": [{"code": "CLI_SPEC",
                  "message": "Invalid command arguments; use --help for the interface."}]}
    print(json.dumps(report, ensure_ascii=True, sort_keys=True))
    return 0 if report["status"] == "ok" else 1


if __name__ == "__main__":
    sys.exit(main())
