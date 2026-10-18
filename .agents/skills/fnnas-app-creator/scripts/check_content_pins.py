#!/usr/bin/env python3
"""Read-only content pin checking. This is not a native runtime audit."""

import argparse
import ast
import errno
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys

DEFAULT_MAX_BYTES = 131072
HARD_MAX_BYTES = 1048576
SHA_PATTERN = re.compile(r"[0-9a-fA-F]{64}\Z")
NAME_PATTERN = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\Z")
AUDIT_NOTICE = "Content pins do not exempt the project from the complete native runtime audit."


class CheckError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


class JsonParser(argparse.ArgumentParser):
    def error(self, message):
        raise CheckError("CLI_SPEC", "Invalid command arguments; use --help for the interface.")


def relative_parts(value):
    if not isinstance(value, str) or not value or "\x00" in value or "\\" in value:
        raise CheckError("PATH_SPEC", "An edge path must be a nonempty relative POSIX path.")
    path = Path(value)
    if path.is_absolute() or any(part == ".." for part in path.parts):
        raise CheckError("PATH_ESCAPE", "Absolute paths and parent traversal are forbidden.")
    if not path.parts or any(part in ("", ".") for part in value.split("/")):
        raise CheckError("PATH_SPEC", "An edge path must identify a file without empty or dot components.")
    return path.parts


def installed_tree(path):
    parts = path.parts
    return ("@appcenter" in parts or parts[:3] == ("/", "var", "packages") or
            (parts[:3] == ("/", "var", "apps") and "target" in parts[3:]))


def open_directory(parent, part):
    info = os.stat(part, dir_fd=parent, follow_symlinks=False)
    if stat.S_ISLNK(info.st_mode):
        raise CheckError("SYMLINK", "Symlink path components are forbidden.")
    if not stat.S_ISDIR(info.st_mode):
        raise CheckError("NOT_DIRECTORY", "An intermediate path component is not a directory.")
    descriptor = os.open(part, os.O_PATH | os.O_DIRECTORY | os.O_NOFOLLOW |
                         getattr(os, "O_CLOEXEC", 0), dir_fd=parent)
    if not stat.S_ISDIR(os.fstat(descriptor).st_mode):
        os.close(descriptor)
        raise CheckError("NOT_DIRECTORY", "An opened path component is not a directory.")
    return descriptor


def open_root(path):
    descriptor = os.open(path.anchor, os.O_PATH | os.O_DIRECTORY | os.O_NOFOLLOW |
                         getattr(os, "O_CLOEXEC", 0))
    try:
        if not stat.S_ISDIR(os.fstat(descriptor).st_mode):
            raise CheckError("NOT_DIRECTORY", "The root anchor is not a directory.")
        for part in path.parts[1:]:
            following = open_directory(descriptor, part)
            os.close(descriptor)
            descriptor = following
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def read_bounded(root_descriptor, parts, limit):
    directory = os.dup(root_descriptor)
    descriptor = None
    try:
        for part in parts[:-1]:
            following = open_directory(directory, part)
            os.close(directory)
            directory = following
        before = os.stat(parts[-1], dir_fd=directory, follow_symlinks=False)
        if stat.S_ISLNK(before.st_mode):
            raise CheckError("SYMLINK", "Symlink files are forbidden.")
        descriptor = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK |
                             getattr(os, "O_CLOEXEC", 0), dir_fd=directory)
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise CheckError("NOT_REGULAR", "Only regular files may contain holders or assets.")
        if before.st_size > limit:
            raise CheckError("OVERSIZE", "The file exceeds the configured byte limit.")
        chunks = bytearray()
        while len(chunks) <= limit:
            block = os.read(descriptor, min(65536, limit + 1 - len(chunks)))
            if not block:
                break
            chunks.extend(block)
        if len(chunks) > limit:
            raise CheckError("OVERSIZE", "The bounded read exceeded the configured byte limit.")
        after = os.fstat(descriptor)
        if (before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (
                after.st_size, after.st_mtime_ns, after.st_ctime_ns):
            raise CheckError("FILE_CHANGED", "The file changed during the bounded read.")
        return bytes(chunks)
    finally:
        if descriptor is not None:
            os.close(descriptor)
        os.close(directory)


def assignment_pin(data, name, python_holder):
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        raise CheckError("HOLDER_ENCODING", "The holder is not UTF-8 text.") from None
    if python_holder:
        try:
            tree = ast.parse(text, filename="<pin-holder>")
        except (SyntaxError, ValueError, RecursionError):
            raise CheckError("HOLDER_SYNTAX", "The Python holder has invalid syntax.") from None
        stores = [node for node in ast.walk(tree)
                  if isinstance(node, ast.Name) and node.id == name and
                  isinstance(node.ctx, (ast.Store, ast.Del))]
        bindings = []
        for node in ast.walk(tree):
            if isinstance(node, (ast.Import, ast.ImportFrom)):
                bindings.extend(alias for alias in node.names if
                                (alias.asname or alias.name.split(".")[0]) == name)
            elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                if node.name == name:
                    bindings.append(node)
        assignments = []
        for node in tree.body:
            if isinstance(node, ast.Assign) and len(node.targets) == 1:
                target = node.targets[0]
            elif isinstance(node, ast.AnnAssign):
                target = node.target
            else:
                continue
            if isinstance(target, ast.Name) and target.id == name:
                assignments.append(node)
        if len(stores) + len(bindings) == 0:
            raise CheckError("PIN_MISSING", "The requested pin assignment is missing.")
        if len(stores) + len(bindings) != 1:
            raise CheckError("PIN_DUPLICATE", "The requested pin is bound or modified more than once.")
        if len(assignments) != 1:
            raise CheckError("PIN_NONLITERAL", "The pin must have one top-level simple assignment.")
        value = assignments[0].value
        if not isinstance(value, ast.Constant) or not isinstance(value.value, str):
            raise CheckError("PIN_NONLITERAL", "The pin must be a literal string, not a computed value.")
        literal = value.value
    else:
        prefix = re.compile(r"^[ \t]*(?:export[ \t]+)?" + re.escape(name) +
                            r"[ \t]*(?:=|:=|\+=)", re.MULTILINE)
        lines = [line for line in text.splitlines() if prefix.match(line)]
        if not lines:
            raise CheckError("PIN_MISSING", "The requested anchored pin assignment is missing.")
        if len(lines) != 1:
            raise CheckError("PIN_DUPLICATE", "The requested anchored pin assignment is repeated.")
        match = re.fullmatch(r"[ \t]*" + re.escape(name) +
                             r"[ \t]*=[ \t]*(['\"])([^'\"\r\n]*)\1[ \t]*(?:#.*)?", lines[0])
        if match is None:
            raise CheckError("PIN_NONLITERAL", "The anchored pin must be one quoted literal assignment.")
        literal = match.group(2)
    if SHA_PATTERN.fullmatch(literal) is None:
        raise CheckError("PIN_SHA", "The literal pin must contain exactly 64 hexadecimal characters.")
    return literal.lower()


def os_issue(error):
    if isinstance(error, CheckError):
        return error.code, error.message
    if isinstance(error, FileNotFoundError):
        return "MISSING_FILE", "A required project file or directory is missing."
    if isinstance(error, PermissionError):
        return "READ_PERMISSION", "A required project file or directory is not readable."
    if isinstance(error, OSError) and error.errno == errno.ELOOP:
        return "SYMLINK", "Symlink files or directory components are forbidden."
    return "READ_ERROR", "A required project file or directory could not be read."


def check_project(project_path, edges, max_bytes=DEFAULT_MAX_BYTES):
    report = {"status": "error", "project": str(project_path), "max_bytes": max_bytes,
              "edges": [], "issues": [], "notice": AUDIT_NOTICE}
    descriptor = None
    try:
        if isinstance(max_bytes, bool) or not isinstance(max_bytes, int) or not 1 <= max_bytes <= HARD_MAX_BYTES:
            raise CheckError("MAX_BYTES", "The byte limit must be between 1 and 1048576.")
        if not edges:
            raise CheckError("EDGE_SPEC", "At least one three-part edge is required.")
        root = Path(project_path).resolve(strict=True)
        report["project"] = str(root)
        if installed_tree(root):
            raise CheckError("INSTALLED_PROJECT", "This checker accepts workspace projects, not App Center installation trees.")
        if not all(hasattr(os, flag) for flag in ("O_PATH", "O_NOFOLLOW", "O_NONBLOCK", "O_DIRECTORY")):
            raise CheckError("PLATFORM", "Descriptor-bound no-follow directory reads are required.")
        descriptor = open_root(root)
        cache = {}
        for index, spec in enumerate(edges):
            row = {"edge": index}
            report["edges"].append(row)
            try:
                if not isinstance(spec, (tuple, list)) or len(spec) != 3:
                    raise CheckError("EDGE_SPEC", "Each edge requires holder, constant, and asset.")
                holder, constant, asset = spec
                if not isinstance(constant, str) or NAME_PATTERN.fullmatch(constant) is None:
                    raise CheckError("CONSTANT_SPEC", "The constant must be a Python-style identifier.")
                holder_parts = relative_parts(holder)
                asset_parts = relative_parts(asset)
                row.update(holder=holder, constant=constant, asset=asset)
                for path, parts in ((holder, holder_parts), (asset, asset_parts)):
                    if path not in cache:
                        data = read_bounded(descriptor, parts, max_bytes)
                        cache[path] = (data, hashlib.sha256(data).hexdigest())
                    data, digest = cache[path]
                    if path == holder:
                        row.update(holder_sha256=digest, holder_bytes=len(data))
                    if path == asset:
                        row.update(actual_sha256=digest, asset_bytes=len(data))
                holder_data, _ = cache[holder]
                _, asset_sha = cache[asset]
                expected = assignment_pin(holder_data, constant, holder.endswith(".py"))
                row["expected_sha256"] = expected
                row["matches"] = expected == asset_sha
                if expected != asset_sha:
                    raise CheckError("PIN_DRIFT", "The pinned digest does not match the actual asset bytes.")
            except (CheckError, OSError, ValueError, TypeError) as error:
                code, message = os_issue(error)
                report["issues"].append({"edge": index, "code": code, "message": message})
        report["status"] = "ok" if not report["issues"] else "error"
    except (CheckError, OSError, ValueError, TypeError) as error:
        code, message = os_issue(error)
        report["issues"].append({"code": code, "message": message})
    finally:
        if descriptor is not None:
            os.close(descriptor)
    return report


def main(argv=None):
    parser = JsonParser(add_help=False)
    parser.add_argument("--help", action="store_true")
    parser.add_argument("--project-path")
    parser.add_argument("--edge", nargs=3, action="append", default=[])
    parser.add_argument("--max-bytes", type=int, default=DEFAULT_MAX_BYTES)
    try:
        args = parser.parse_args(argv)
        if args.help:
            report = {"status": "ok", "usage": "check_content_pins.py --project-path PATH --edge HOLDER CONSTANT ASSET [--edge HOLDER CONSTANT ASSET ...] [--max-bytes N]",
                      "default_max_bytes": DEFAULT_MAX_BYTES, "hard_max_bytes": HARD_MAX_BYTES,
                      "notice": AUDIT_NOTICE}
        elif not args.project_path:
            raise CheckError("CLI_SPEC", "--project-path is required.")
        else:
            report = check_project(args.project_path, args.edge, args.max_bytes)
    except CheckError as error:
        report = {"status": "error", "edges": [], "issues": [{"code": error.code,
                  "message": error.message}], "notice": AUDIT_NOTICE}
    print(json.dumps(report, ensure_ascii=True, sort_keys=True))
    return 0 if report["status"] == "ok" else 1


if __name__ == "__main__":
    sys.exit(main())
