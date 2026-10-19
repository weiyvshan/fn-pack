#!/usr/bin/env bash
#
# Resolve and validate the fnpack binary bundled with this skill.
# Debian/Linux-native replacement for the former resolve-fnpack.ps1.
#
# On success the resolved absolute path is the only thing written to stdout.
set -uo pipefail

prog="resolve-fnpack.sh"

die() {
    printf '%s: %s\n' "$prog" "$*" >&2
    exit 1
}

usage() {
    cat <<EOF
Usage: $prog [--skill-root DIR] [--platform PLATFORM] [--arch ARCH] [--bundled-only]

Resolves the validated fnpack executable for this host.
  --skill-root DIR   Skill directory containing bin/ (default: parent of this script)
  --platform NAME    windows | linux (default: detected from uname)
  --arch NAME        x64/amd64 | arm64/aarch64 (default: detected from uname -m)
  --bundled-only     Do not fall back to a fnpack found on PATH
EOF
}

skill_root=""
platform=""
architecture=""
bundled_only=0

while [ $# -gt 0 ]; do
    case "$1" in
        --skill-root) [ $# -ge 2 ] || die "--skill-root requires a value"; skill_root=$2; shift 2 ;;
        --platform) [ $# -ge 2 ] || die "--platform requires a value"; platform=$2; shift 2 ;;
        --arch|--architecture) [ $# -ge 2 ] || die "$1 requires a value"; architecture=$2; shift 2 ;;
        --bundled-only) bundled_only=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown argument: $1" ;;
    esac
done

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P) ||
    die "cannot determine the script directory"
if [ -z "$skill_root" ]; then
    skill_root=$(CDPATH= cd -- "$script_dir/.." && pwd -P) ||
        die "cannot determine the skill root"
else
    skill_root=$(CDPATH= cd -- "$skill_root" && pwd -P) ||
        die "skill root is not a directory: $skill_root"
fi

if [ -z "$platform" ]; then
    case "$(uname -s)" in
        Linux*) platform=linux ;;
        MINGW*|MSYS*|CYGWIN*|Windows*) platform=windows ;;
        *) platform=$(uname -s) ;;
    esac
fi
if [ -z "$architecture" ]; then
    architecture=$(uname -m)
fi

normalized_platform=$(printf '%s' "$platform" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
normalized_architecture=$(printf '%s' "$architecture" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
case "$normalized_architecture" in
    amd64|x86_64|x64) normalized_architecture=x64 ;;
    aarch64|arm64) normalized_architecture=arm64 ;;
esac

case "$normalized_platform/$normalized_architecture" in
    windows/x64)
        asset_name="fnpack.exe"
        binary_format="pe-x64"
        ;;
    linux/x64)
        asset_name="fnpack-1.2.3-linux-amd64"
        binary_format="elf-x64"
        ;;
    linux/arm64)
        asset_name="fnpack-1.2.3-linux-arm64"
        binary_format="elf-arm64"
        ;;
    *)
        die "bundled fnpack does not support platform $platform architecture $architecture"
        ;;
esac

read_bytes() {
    # read_bytes FILE OFFSET COUNT -> one decimal byte value per line
    od -An -v -tu1 -j "$2" -N "$3" -- "$1" 2>/dev/null | tr -s ' \n' '\n' | sed '/^$/d'
}

file_size() {
    wc -c < "$1" 2>/dev/null | tr -d ' '
}

assert_elf() {
    local path=$1 expected_machine=$2 arch_label=$3
    local size bytes=()
    size=$(file_size "$path")
    [ -n "$size" ] || size=0
    mapfile -t bytes < <(read_bytes "$path" 0 20)

    if [ "$size" -lt 20 ] || [ "${#bytes[@]}" -lt 20 ] ||
        [ "${bytes[0]}" -ne 127 ] || [ "${bytes[1]}" -ne 69 ] ||
        [ "${bytes[2]}" -ne 76 ] || [ "${bytes[3]}" -ne 70 ] ||
        [ "${bytes[4]}" -ne 2 ] || [ "${bytes[5]}" -ne 1 ]; then
        die "Linux fnpack is not a $arch_label ELF executable: $path"
    fi

    local machine=$(( bytes[18] + bytes[19] * 256 ))
    [ "$machine" -eq "$expected_machine" ] ||
        die "Linux fnpack is not a $arch_label ELF executable: $path"
    [ -x "$path" ] || die "Linux fnpack is not executable: $path"
}

assert_pe() {
    local path=$1
    local size header=() signature=()
    size=$(file_size "$path")
    [ -n "$size" ] || size=0
    mapfile -t header < <(read_bytes "$path" 0 2)

    if [ "$size" -lt 64 ] || [ "${#header[@]}" -lt 2 ] ||
        [ "${header[0]}" -ne 77 ] || [ "${header[1]}" -ne 90 ]; then
        die "Bundled Windows fnpack is not a PE executable: $path"
    fi

    mapfile -t header < <(read_bytes "$path" 60 4)
    [ "${#header[@]}" -eq 4 ] ||
        die "Bundled Windows fnpack is not a PE executable: $path"
    local pe_offset=$(( header[0] + header[1] * 256 + header[2] * 65536 + header[3] * 16777216 ))
    [ $(( pe_offset + 6 )) -le "$size" ] ||
        die "Bundled Windows fnpack is not a PE executable: $path"

    mapfile -t signature < <(read_bytes "$path" "$pe_offset" 6)
    [ "${#signature[@]}" -eq 6 ] ||
        die "Bundled Windows fnpack is not a PE executable: $path"
    if [ "${signature[0]}" -ne 80 ] || [ "${signature[1]}" -ne 69 ] ||
        [ "${signature[2]}" -ne 0 ] || [ "${signature[3]}" -ne 0 ]; then
        die "Bundled Windows fnpack is not a PE executable: $path"
    fi

    local machine=$(( signature[4] + signature[5] * 256 ))
    [ "$machine" -eq 34404 ] ||
        die "Bundled Windows fnpack is not an x86-64 PE executable: $path"
}

assert_binary() {
    case "$binary_format" in
        elf-x64) assert_elf "$1" 62 "x86-64" ;;
        elf-arm64) assert_elf "$1" 183 "ARM64" ;;
        pe-x64) assert_pe "$1" ;;
    esac
}

bundled_path="$skill_root/bin/$asset_name"
if [ -f "$bundled_path" ]; then
    resolved=$(CDPATH= cd -- "$(dirname -- "$bundled_path")" && pwd -P)/$(basename -- "$bundled_path")
    assert_binary "$resolved"
    printf '%s\n' "$resolved"
    exit 0
fi

if [ "$bundled_only" -ne 1 ]; then
    fallback=$(command -v fnpack 2>/dev/null) || fallback=""
    if [ -n "$fallback" ]; then
        assert_binary "$fallback"
        printf '%s\n' "$fallback"
        exit 0
    fi
fi

die "fnpack was not found for $normalized_platform/$normalized_architecture. Expected bundled asset: $bundled_path"
