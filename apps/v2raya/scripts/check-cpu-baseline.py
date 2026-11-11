#!/usr/bin/env python3
"""Fail closed unless the ELF Go build info declares Linux AMD64 v1.

Reads inline Go 1.18+ build info without executing the binary or requiring Go.
The build invokes this on both the prepared binary and the FPK payload.
"""
from pathlib import Path
import struct
import sys

MAGIC = b'\xff Go buildinf:'


def read_string(data, offset):
    size = 0
    for shift in range(0, 70, 7):
        if offset >= len(data):
            raise ValueError('truncated Go build info')
        byte = data[offset]
        offset += 1
        size |= (byte & 127) << shift
        if byte < 128:
            end = offset + size
            if end > len(data):
                raise ValueError('truncated Go build string')
            return data[offset:end], end
    raise ValueError('invalid Go build string length')


def verify(data):
    if data[:6] != b'\x7fELF\x02\x01' or len(data) < 64:
        raise ValueError('expected little-endian ELF64')
    if struct.unpack_from('<H', data, 18)[0] != 62:
        raise ValueError('expected x86_64 ELF machine')
    # Read the actual .go.buildinfo section, not arbitrary matching text.
    shoff = struct.unpack_from('<Q', data, 40)[0]
    entsize, count, names_index = struct.unpack_from('<HHH', data, 58)
    if entsize != 64 or not count or names_index >= count or shoff + count * 64 > len(data):
        raise ValueError('invalid ELF section table')
    sections = [struct.unpack_from('<IIQQQQIIQQ', data, shoff + i * 64) for i in range(count)]
    names_section = sections[names_index]
    names = data[names_section[4]:names_section[4] + names_section[5]]
    for section in sections:
        if names[section[0]:].split(b'\0', 1)[0] != b'.go.buildinfo':
            continue
        info = data[section[4]:section[4] + section[5]]
        if len(info) < 32 or not info.startswith(MAGIC) or not info[15] & 2:
            raise ValueError('unsupported Go build info encoding')
        _, offset = read_string(info, 32)
        module, _ = read_string(info, offset)
        if len(module) < 32:
            raise ValueError('missing module build settings')
        lines = module[16:-16].decode('utf-8').splitlines()
        for setting in ('GOOS=linux', 'GOARCH=amd64', 'GOAMD64=v1', 'CGO_ENABLED=0'):
            if 'build\t' + setting not in lines:
                raise ValueError('required build setting missing: ' + setting)
        return
    raise ValueError('missing .go.buildinfo section')


if __name__ == '__main__':
    try:
        verify(Path(sys.argv[1]).read_bytes())
    except (ValueError, OSError, IndexError, struct.error) as error:
        print('CPU baseline rejected: ' + str(error), file=sys.stderr)
        sys.exit(1)
    print('CPU baseline verified: linux/amd64 GOAMD64=v1 CGO_ENABLED=0')
