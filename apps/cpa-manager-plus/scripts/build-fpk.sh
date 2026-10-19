#!/bin/sh
# Build the cpa-manager-plus fnOS package (FPK) on a Debian/fnOS host.
#
# POSIX sh replacement for scripts/build-fpk.ps1. Both bundled components are
# upstream release binaries, so this script needs no frontend toolchain, no Go
# toolchain and no WSL bridge: it verifies the locked artifacts against
# binary.lock.json, assembles the staging tree and runs the bundled Linux
# fnpack, which records POSIX modes directly.
#
# Requires the shared fnpack skill beside the apps/ tree. Locked binaries are
# downloaded on demand to .tmp/; no third-party binary is stored in Git.
set -u

PROJECT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

detect_repo_root() {
    if [ -n "${REPO_ROOT:-}" ]; then
        printf '%s\n' "$REPO_ROOT"
        return 0
    fi
    for candidate in "$PROJECT/.." "$PROJECT/../.."; do
        resolved=$(CDPATH= cd -- "$candidate" 2>/dev/null && pwd) || continue
        if [ -d "$resolved/.agents/skills/fnnas-app-creator" ]; then
            printf '%s\n' "$resolved"
            return 0
        fi
    done
    printf '%s\n' "$PROJECT/../.."
}

REPO_ROOT=$(detect_repo_root)
BUILD_DIR="$REPO_ROOT/build"
TMP_ROOT="$REPO_ROOT/.tmp"
SKILL_ROOT="$REPO_ROOT/.agents/skills/fnnas-app-creator"
AUDIT_SCRIPT="$SKILL_ROOT/scripts/audit_fnos_project.sh"
FNPACK_RESOLVER="$SKILL_ROOT/scripts/resolve-fnpack.sh"
BINARY_ROOT="$TMP_ROOT/cpa-manager-plus-binaries"

STAGE=''
VERIFY_DIR=''
GENERATED_PATH=''
FINALIZED=0

cleanup() {
    for path in "$STAGE" "$VERIFY_DIR"; do
        [ -n "$path" ] && [ -d "$path" ] && rm -rf -- "$path"
    done
    if [ "$FINALIZED" -eq 0 ] && [ -n "$GENERATED_PATH" ] && [ -e "$GENERATED_PATH" ]; then
        rm -f -- "$GENERATED_PATH"
    fi
}
trap cleanup EXIT HUP INT TERM

elf64_amd64_check() {
    _file=$1
    [ -f "$_file" ] || die "ELF input is missing: $_file"
    _magic=$(od -An -tx1 -N4 "$_file" | tr -d ' \n')
    [ "$_magic" = '7f454c46' ] || die "ELF magic mismatch: $_file"
    _class=$(od -An -tu1 -j4 -N1 "$_file" | tr -d ' ')
    _order=$(od -An -tu1 -j5 -N1 "$_file" | tr -d ' ')
    [ "$_class" = '2' ] && [ "$_order" = '1' ] || die "ELF class or byte order mismatch: $_file"
    _machine=$(od -An -tu2 -j18 -N2 "$_file" | awk '{print $1 + 0}')
    [ "$_machine" = '62' ] || die "ELF machine is not x86-64: $_file"
}

lock_field() {
    # lock_field <component> <field> reads the value straight out of the lock.
    python3 - "$PROJECT/binary.lock.json" "$1" "$2" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    lock = json.load(handle)
for component in lock["components"]:
    if component["name"] == sys.argv[2]:
        print(component[sys.argv[3]])
        break
else:
    raise SystemExit("component not found: " + sys.argv[2])
PY
}

lock_component_field() {
    # lock_component_field <index> <field>
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["components"][int(sys.argv[2])][sys.argv[3]])' \
        "$PROJECT/binary.lock.json" "$1" "$2"
}

require_file() {
    [ -e "$1" ] || die "$2"
}

# --- preconditions -----------------------------------------------------------
command -v python3 >/dev/null 2>&1 || die 'python3 is required to read binary.lock.json.'
command -v tar >/dev/null 2>&1 || die 'tar is required to inspect the FPK.'
command -v sha256sum >/dev/null 2>&1 || die 'sha256sum is required to verify binaries.'
command -v md5sum >/dev/null 2>&1 || die 'md5sum is required to verify the app.tgz checksum.'

printf 'Project=%s\n' "$PROJECT"
printf 'RepositoryRoot=%s\n' "$REPO_ROOT"
require_file "$AUDIT_SCRIPT" 'The fnOS static audit script is missing.'
require_file "$FNPACK_RESOLVER" 'The bundled fnpack resolver is missing.'
python3 -B "$PROJECT/scripts/prepare-binaries.py" --cache-dir "$BINARY_ROOT" ||
    die 'Unable to prepare the locked release binaries.'

# --- source contract tests ---------------------------------------------------
sh "$PROJECT/scripts/test-package.sh" || die 'Source package tests failed.'

app_name=$(sed -n 's/^[[:space:]]*appname[[:space:]]*=[[:space:]]*//p' "$PROJECT/manifest" | head -n 1 | tr -d '[:space:]')
version=$(sed -n 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*//p' "$PROJECT/manifest" | head -n 1 | tr -d '[:space:]')
platform=$(sed -n 's/^[[:space:]]*platform[[:space:]]*=[[:space:]]*//p' "$PROJECT/manifest" | head -n 1 | tr -d '[:space:]')
[ -n "$app_name" ] && [ -n "$version" ] || die 'Manifest appname or version is not parseable.'
[ -n "$platform" ] || die 'Manifest platform is not parseable.'

# Installable artifacts use <appname>_<version>_<platform>.fpk, the repository
# convention that the other applications already follow. The older
# <appname>-<version>.fpk form is retired; artifacts built before this change
# keep their existing names so their recorded hashes stay traceable.
TARGET_PATH="$BUILD_DIR/${app_name}_${version}_${platform}.fpk"
GENERATED_PATH="$BUILD_DIR/$app_name.fpk"
mkdir -p "$BUILD_DIR" "$TMP_ROOT"
[ -e "$TARGET_PATH" ] && die "Refusing to overwrite existing artifact: $TARGET_PATH"
[ -e "$GENERATED_PATH" ] && die "Refusing to overwrite unversioned fnpack output: $GENERATED_PATH"

STAGE=$(mktemp -d "$TMP_ROOT/cpa-manager-plus-stage.XXXXXX")
VERIFY_DIR=$(mktemp -d "$TMP_ROOT/cpa-manager-plus-verify.XXXXXX")

# --- staging tree ------------------------------------------------------------
# Copy the maintained directories first: creating app/bin before copying app
# would make `cp -a app stage/app` nest the tree as stage/app/app.
for directory in app cmd config wizard; do
    cp -a "$PROJECT/$directory" "$STAGE/$directory"
done
mkdir -p "$STAGE/app/bin"
cp "$PROJECT/manifest" "$PROJECT/ICON.PNG" "$PROJECT/ICON_256.PNG" "$STAGE/"
cp "$PROJECT/THIRD_PARTY_NOTICES.md" "$STAGE/app/THIRD_PARTY_NOTICES.md"
cp "$PROJECT/binary.lock.json" "$STAGE/app/component-lock.json"

# --- locked release binaries -------------------------------------------------
# Every component is an upstream release artifact: verify byte count, SHA-256
# and ELF header, then stage it under its packaged name.
component_count=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["components"]))' "$PROJECT/binary.lock.json") ||
    die 'Unable to read the component lock.'
[ "$component_count" -ge 1 ] || die 'binary.lock.json declares no components.'

index=0
while [ "$index" -lt "$component_count" ]; do
    name=$(lock_component_field "$index" name)
    component_version=$(lock_field "$name" version)
    expected_bytes=$(lock_field "$name" bytes)
    expected_hash=$(lock_field "$name" sha256)
    release_binary="$BINARY_ROOT/$name/$component_version/$name"
    require_file "$release_binary" "Locked release binary is missing: $name ($release_binary)"
    actual_bytes=$(stat -c '%s' "$release_binary")
    actual_hash=$(sha256sum "$release_binary" | awk '{print $1}')
    [ "$actual_bytes" = "$expected_bytes" ] ||
        die "Byte count mismatch for $name (actual=$actual_bytes, expected=$expected_bytes)."
    [ "$actual_hash" = "$expected_hash" ] ||
        die "SHA-256 mismatch for $name (actual=$actual_hash, expected=$expected_hash)."
    elf64_amd64_check "$release_binary"
    cp "$release_binary" "$STAGE/app/bin/$name"
    printf 'Component=%s version=%s bytes=%s\n' "$name" "$(lock_field "$name" version)" "$actual_bytes"
    index=$((index + 1))
done

# --- permissions and line endings -------------------------------------------
# Files copied into the staging tree inherit the parent directory mode on this
# filesystem, so every mode is set explicitly instead of being left to cp.
for script in "$STAGE"/cmd/*; do
    tr -d '\r' < "$script" > "$script.lf" && mv "$script.lf" "$script"
done
find "$STAGE" -type d -exec chmod 0755 {} +
find "$STAGE" -type f -exec chmod 0644 {} +
chmod 0755 "$STAGE"/cmd/* "$STAGE/app/bin"/*

# --- static audit ------------------------------------------------------------
bash "$AUDIT_SCRIPT" --project-path "$STAGE" --format text ||
    die 'fnOS static audit failed for the complete staging tree.'

# --- package -----------------------------------------------------------------
fnpack_bin=$(bash "$FNPACK_RESOLVER" --bundled-only) ||
    die 'Unable to resolve the bundled fnpack binary.'
printf 'fnpack=%s\n' "$fnpack_bin"
(
    cd "$BUILD_DIR" && "$fnpack_bin" build --directory "$STAGE"
) || die 'fnpack failed.'
require_file "$GENERATED_PATH" "fnpack did not produce the expected file: $GENERATED_PATH"
mv -- "$GENERATED_PATH" "$TARGET_PATH"
FINALIZED=1

# --- artifact verification ---------------------------------------------------
for required in \
    'manifest' 'app.tgz' 'ICON.PNG' 'ICON_256.PNG' 'cmd/main' 'cmd/install_callback' \
    'cmd/upgrade_callback' 'cmd/uninstall_callback' 'config/privilege' 'config/resource' \
    'wizard/install' 'wizard/uninstall'
do
    tar -tf "$TARGET_PATH" | sed 's|^\./||' | grep -qx "$required" ||
        die "Final FPK is missing outer entry: $required"
done

outer_modes=$(tar -tvf "$TARGET_PATH")
for required_executable in \
    'cmd/installer' 'cmd/main' 'cmd/install_init' 'cmd/install_callback' \
    'cmd/upgrade_init' 'cmd/upgrade_callback' 'cmd/uninstall_init' 'cmd/uninstall_callback'
do
    mode_line=$(printf '%s\n' "$outer_modes" | grep -E "[[:space:]]${required_executable}\$" | head -n 1)
    [ -n "$mode_line" ] || die "Final FPK entry is missing: $required_executable"
    case "$mode_line" in
        -rwx*) : ;;
        *) die "Final FPK entry is not executable: $required_executable" ;;
    esac
done

tar -xf "$TARGET_PATH" -C "$VERIFY_DIR" || die 'Unable to extract the final FPK.'
app_tgz="$VERIFY_DIR/app.tgz"
require_file "$app_tgz" 'Final FPK does not contain app.tgz.'
for required_nested in \
    'bin/cpa-manager-plus' 'bin/cli-proxy-api' 'component-lock.json' 'defaults/cli-proxy-api.yaml'
do
    tar -tzf "$app_tgz" | sed 's|^\./||' | grep -qx "$required_nested" ||
        die "Final app.tgz is missing entry: $required_nested"
done
if tar -tzf "$app_tgz" | grep -q 'upstream\|README\|\.patch$'; then
    die 'Final app.tgz contains upstream sources, release docs or patches.'
fi

manifest_checksum=$(sed -n 's/^[[:space:]]*checksum[[:space:]]*=[[:space:]]*//p' "$VERIFY_DIR/manifest" | head -n 1 | tr -d '[:space:]')
app_tgz_checksum=$(md5sum "$app_tgz" | awk '{print $1}')
[ "$manifest_checksum" = "$app_tgz_checksum" ] ||
    die "FPK manifest checksum does not match app.tgz (manifest=$manifest_checksum, app.tgz=$app_tgz_checksum)."
grep -Eq "^[[:space:]]*version[[:space:]]*=[[:space:]]*$version[[:space:]]*$" "$VERIFY_DIR/manifest" ||
    die "Final FPK manifest is not version $version."

artifact_bytes=$(stat -c '%s' "$TARGET_PATH")
artifact_hash=$(sha256sum "$TARGET_PATH" | awk '{print $1}')
printf 'Artifact=%s\n' "$TARGET_PATH"
printf 'Bytes=%s\n' "$artifact_bytes"
printf 'SHA256=%s\n' "$artifact_hash"
printf 'AppTgzChecksum=%s\n' "$app_tgz_checksum"
printf 'Version=%s\n' "$version"
printf 'Result=passed\n'
