#!/usr/bin/env python3
"""Normalize the outer app.tgz TAR mode, preserving all decoded payload bytes."""
import argparse
from contextlib import ExitStack
import gzip
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import tarfile
import tempfile
import zlib

BLOCK = tarfile.BLOCKSIZE
MODE_SLICE = slice(100, 108)
CHECKSUM_SLICE = slice(148, 156)
TIMESTAMP_PAX_FIELDS = {"mtime", "atime", "ctime"}


def padded(size):
    return (size + BLOCK - 1) // BLOCK * BLOCK


def inspect_tar(source, size):
    if size % BLOCK:
        raise ValueError("decoded input must be a block-aligned TAR")
    with tarfile.open(fileobj=source, mode="r:") as archive:
        members = archive.getmembers()
        for entry in members:
            path = PurePosixPath(entry.name)
            if path.is_absolute() or ".." in path.parts or path.as_posix().startswith("app.tgz/"):
                raise ValueError("unsafe or ambiguous TAR member path")
        selected = [member for member in members
                    if PurePosixPath(member.name).as_posix() == "app.tgz"]
        if len(selected) != 1:
            raise ValueError("TAR must contain exactly one app.tgz member")
        member = selected[0]
        if member.type not in (tarfile.REGTYPE, tarfile.AREGTYPE) or member.sparse:
            raise ValueError("app.tgz must be a plain regular file")
        if set(member.pax_headers) - TIMESTAMP_PAX_FIELDS:
            raise ValueError("unsupported PAX override on app.tgz")
        offset = member.offset_data - BLOCK
        if offset < 0 or offset % BLOCK or offset < member.offset:
            raise ValueError("invalid app.tgz header offset")
        source.seek(offset)
        block = source.read(BLOCK)
        header = tarfile.TarInfo.frombuf(block, archive.encoding, archive.errors)
        if (header.name != "app.tgz" or member.name != "app.tgz"
                or header.type != member.type or header.size != member.size
                or header.mode != member.mode or header.linkname):
            raise ValueError("ambiguous or overridden app.tgz header")
        end = 0
        for entry in members:
            if entry.size < 0 or entry.offset_data < BLOCK or entry.offset_data % BLOCK:
                raise ValueError("invalid TAR member bounds")
            end = max(end, entry.offset_data + padded(entry.size))
        if size - end < 2 * BLOCK:
            raise ValueError("truncated TAR payload or missing end markers")
        source.seek(end)
        while True:
            tail = source.read(1024 * 1024)
            if not tail:
                break
            if tail.strip(b"\0"):
                raise ValueError("invalid or concatenated TAR data after its members")
    result = bytearray(block)
    if header.mode != 0o644:
        result[MODE_SLICE] = b"0000644\0"
        result[CHECKSUM_SLICE] = b" " * 8
        result[CHECKSUM_SLICE] = ("%06o\0 " % sum(result)).encode("ascii")
        updated = tarfile.TarInfo.frombuf(bytes(result), "utf-8", "surrogateescape")
        if updated.name != "app.tgz" or updated.mode != 0o644:
            raise ValueError("normalized TAR header did not validate")
    return offset, block, bytes(result), header.mode


def identity(info):
    return info.st_dev, info.st_ino


def source_snapshot(info):
    return identity(info), info.st_size, info.st_mtime_ns, info.st_ctime_ns


def patch_header(output, offset, after):
    output.seek(offset + MODE_SLICE.start)
    output.write(after[MODE_SLICE])
    output.seek(offset + CHECKSUM_SLICE.start)
    output.write(after[CHECKSUM_SLICE])


def normalize_fpk(raw, named):
    raw = Path(raw)
    named = Path(named).absolute()
    created = None
    with ExitStack() as stack:
        source = stack.enter_context(raw.open("rb"))
        initial = os.fstat(source.fileno())
        if not stat.S_ISREG(initial.st_mode):
            raise ValueError("input must be a regular file")
        magic = source.read(2)
        source.seek(0)
        kind = "gzip" if magic == b"\x1f\x8b" else "tar"
        decoded = source
        if kind == "gzip":
            decoded = stack.enter_context(tempfile.TemporaryFile(mode="w+b"))
            # Reading to EOF validates deflate, CRC and truncation before output
            # creation. No format auto-detection or fallback is used.
            with gzip.GzipFile(fileobj=source, mode="rb") as compressed:
                shutil.copyfileobj(compressed, decoded, length=1024 * 1024)
            decoded.seek(0)
        offset, before, after, original_mode = inspect_tar(decoded, os.fstat(decoded.fileno()).st_size)
        if source_snapshot(os.fstat(source.fileno())) != source_snapshot(initial):
            raise ValueError("input changed during archive validation")
        try:
            # xb rejects regular files, directories and even dangling symlinks.
            with named.open("xb") as output:
                created = os.fstat(output.fileno())
                if before == after:
                    source.seek(0)
                    shutil.copyfileobj(source, output, length=1024 * 1024)
                elif kind == "tar":
                    source.seek(0)
                    shutil.copyfileobj(source, output, length=1024 * 1024)
                    patch_header(output, offset, after)
                else:
                    patch_header(decoded, offset, after)
                    decoded.seek(0)
                    with gzip.GzipFile(filename="", mode="wb", compresslevel=6,
                                       fileobj=output, mtime=0) as compressed:
                        shutil.copyfileobj(decoded, compressed, length=1024 * 1024)
                if source_snapshot(os.fstat(source.fileno())) != source_snapshot(initial):
                    raise ValueError("input changed during copying")
                os.fchmod(output.fileno(), 0o644)
        except BaseException:
            # Remove only the exact file this call created, never an old target.
            if created is not None:
                try:
                    current = named.lstat()
                    if stat.S_ISREG(current.st_mode) and identity(current) == identity(created):
                        named.unlink()
                except FileNotFoundError:
                    pass
            raise
    return {
        "source": str(raw), "output": str(named), "format": kind,
        "header_offset": offset, "original_mode": "%04o" % original_mode,
        "normalized_mode": "0644", "changed": before != after,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("raw", type=Path)
    parser.add_argument("named", type=Path)
    args = parser.parse_args()
    try:
        result = normalize_fpk(args.raw, args.named)
    except (OSError, EOFError, ValueError, tarfile.TarError, zlib.error) as error:
        parser.exit(1, "normalize-fpk: %s\n" % error)
    print(json.dumps(result))


if __name__ == "__main__":
    main()
