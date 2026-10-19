#!/bin/sh
# Build the Sub2API fnOS package (FPK) on a Linux host.
#
# POSIX replacement for scripts/build-fpk.ps1, which now only forwards here.
# Sub2API is a Docker application: the payload is the Compose project, the
# lifecycle hooks and the pinned image digests, so building needs no PowerShell,
# no WSL bridge and no container runtime.
#
# The artifact name follows the repository convention
# <appname>_<version>_<platform>.fpk; the platform is read from the manifest.
set -u

PROJECT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

STAGE=
VERIFY_DIR=
GENERATED_PATH=
TARGET_PATH=
FINALIZED=0

die() {
    printf 'build-fpk: %s\n' "$1" >&2
    exit 1
}

cleanup() {
    exit_status=$?
    if [ -n "$GENERATED_PATH" ] && [ -f "$GENERATED_PATH" ]; then
        rm -f -- "$GENERATED_PATH"
    fi
    if [ "$FINALIZED" -ne 1 ] && [ -n "$TARGET_PATH" ] && [ -f "$TARGET_PATH" ]; then
        rm -f -- "$TARGET_PATH"
    fi
    for directory in "$STAGE" "$VERIFY_DIR"; do
        if [ -n "$directory" ] && [ -d "$directory" ]; then
            rm -rf -- "$directory"
        fi
    done
    exit "$exit_status"
}
trap cleanup EXIT HUP INT TERM

detect_repo_root() {
    if [ -n "${REPO_ROOT:-}" ]; then
        printf '%s\n' "$REPO_ROOT"
        return 0
    fi
    for candidate in "$PROJECT/.." "$PROJECT/../.."; do
        if [ -d "$candidate/.agents/skills/fnnas-app-creator" ]; then
            (CDPATH= cd -- "$candidate" && pwd)
            return 0
        fi
    done
    return 1
}

strip_crlf() {
    [ -f "$1" ] || return 0
    tr -d '\r' < "$1" > "$1.lf" || die "Unable to normalize line endings in $1"
    mv -f -- "$1.lf" "$1"
}

manifest_value() {
    sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*//p" "$1" | head -n 1 | tr -d '[:space:]'
}

assert_executable_entry() {
    # $1 = mode listing, $2 = archive entry, $3 = description
    pattern="[[:space:]]$(printf '%s' "$2" | sed 's/[][\.*^$()+?{}|]/\\&/g')\$"
    count=$(grep -Ec -- "$pattern" "$1")
    [ "$count" = "1" ] || die "Final $3 entry is not uniquely present ($count matches): $2"
    mode_line=$(grep -E -- "$pattern" "$1" | head -n 1)
    case "$mode_line" in
        -??x*) ;;
        *) die "Final $3 entry is not executable: $2" ;;
    esac
}

[ "$(uname -s)" = "Linux" ] || die 'This build script must run on Linux; use scripts/build-fpk.ps1 on Windows.'

REPO_ROOT=$(detect_repo_root) || die 'Unable to locate the repository root (no .agents/skills/fnnas-app-creator found); set REPO_ROOT.'
# Installable artifacts and build scratch space belong to the repository, not to
# the package tree: that is where the other apps publish their FPKs too.
BUILD_DIR="$REPO_ROOT/build"
TMP_ROOT="$REPO_ROOT/.tmp"

FNPACK_RESOLVER="$REPO_ROOT/.agents/skills/fnnas-app-creator/scripts/resolve-fnpack.sh"
AUDIT_SCRIPT="$REPO_ROOT/.agents/skills/fnnas-app-creator/scripts/audit_fnos_project.sh"
[ -f "$FNPACK_RESOLVER" ] || die "Missing fnpack resolver: $FNPACK_RESOLVER"
[ -f "$AUDIT_SCRIPT" ] || die "Missing fnOS audit script: $AUDIT_SCRIPT"
command -v md5sum >/dev/null 2>&1 || die 'md5sum is required to verify the app.tgz checksum.'

printf '==> Verifying the package contract\n'
bash "$PROJECT/scripts/test-package.sh" || die 'Source package tests failed.'

app_name=$(manifest_value "$PROJECT/manifest" appname)
version=$(manifest_value "$PROJECT/manifest" version)
platform=$(manifest_value "$PROJECT/manifest" platform)
[ -n "$app_name" ] || die 'The manifest does not declare appname.'
[ -n "$version" ] || die 'The manifest does not declare version.'
[ -n "$platform" ] || die 'The manifest does not declare platform.'

TARGET_PATH="$BUILD_DIR/${app_name}_${version}_${platform}.fpk"
GENERATED_PATH="$BUILD_DIR/$app_name.fpk"

mkdir -p -- "$TMP_ROOT" "$BUILD_DIR" || die 'Unable to create the build directories.'
[ -e "$TARGET_PATH" ] && die "Refusing to overwrite existing artifact: $TARGET_PATH"
[ -e "$GENERATED_PATH" ] && die "Refusing to overwrite unversioned fnpack output: $GENERATED_PATH"

STAGE=$(mktemp -d "$TMP_ROOT/${app_name}-stage.XXXXXX") || die 'Unable to create the staging directory.'
VERIFY_DIR=$(mktemp -d "$TMP_ROOT/${app_name}-verify.XXXXXX") || die 'Unable to create the verification directory.'

printf '==> Staging %s %s (%s)\n' "$app_name" "$version" "$platform"
for directory in app cmd config wizard; do
    [ -d "$PROJECT/$directory" ] || die "Missing packaging directory: $directory"
    cp -a -- "$PROJECT/$directory" "$STAGE/$directory" || die "Unable to stage $directory"
done
for file in manifest ICON.PNG ICON_256.PNG; do
    [ -f "$PROJECT/$file" ] || die "Missing packaging file: $file"
    cp -a -- "$PROJECT/$file" "$STAGE/$file" || die "Unable to stage $file"
done

# fnOS shell hooks must reach the device as LF; the working tree may carry CRLF.
for script in "$STAGE"/cmd/*; do
    strip_crlf "$script"
done
for script in "$STAGE"/app/docker/scripts/*.sh; do
    strip_crlf "$script"
done

find "$STAGE" -type d -exec chmod 0755 {} +
find "$STAGE" -type f -exec chmod 0644 {} +
chmod 0755 "$STAGE"/cmd/* "$STAGE"/app/docker/scripts/*.sh
# The credential directory is bind-mounted into the containers, so it and every
# credential file inside it stay private while app/docker/scripts remains
# executable.
[ -d "$STAGE/app/docker/runtime-secrets" ] ||
    die 'The payload must ship app/docker/runtime-secrets as a mountable credential directory.'
chmod 0700 "$STAGE/app/docker/runtime-secrets"
find "$STAGE/app/docker/runtime-secrets" -type f -exec chmod 0600 {} +

printf '==> Auditing the staging tree\n'
audit_log="$VERIFY_DIR/audit.log"
if ! bash "$AUDIT_SCRIPT" --project-path "$STAGE" > "$audit_log" 2>&1; then
    cat "$audit_log" >&2
    die 'fnOS static audit failed for the complete staging tree.'
fi

fnpack_bin=$(bash "$FNPACK_RESOLVER" --bundled-only) || die 'Unable to resolve the bundled fnpack binary.'
[ -x "$fnpack_bin" ] || die "Resolved fnpack is not executable: $fnpack_bin"

printf '==> Packing with %s\n' "$fnpack_bin"
( cd "$BUILD_DIR" && "$fnpack_bin" build --directory "$STAGE" ) || die "fnpack failed for $STAGE"
[ -f "$GENERATED_PATH" ] || die "fnpack did not produce the expected file: $GENERATED_PATH"
mv -f -- "$GENERATED_PATH" "$TARGET_PATH" || die "Unable to move the artifact to $TARGET_PATH"
FINALIZED=1

printf '==> Verifying %s\n' "$TARGET_PATH"
outer_entries="$VERIFY_DIR/outer-entries.txt"
outer_modes="$VERIFY_DIR/outer-modes.txt"
tar -tf "$TARGET_PATH" | sed 's|^\./||' > "$outer_entries" || die 'Unable to list the final FPK.'
tar -tvf "$TARGET_PATH" > "$outer_modes" || die 'Unable to inspect final FPK modes.'

for required in manifest app.tgz ICON.PNG ICON_256.PNG cmd/main cmd/installer \
    config/privilege config/resource wizard/install
do
    grep -qx -- "$required" "$outer_entries" || die "Final FPK is missing outer entry: $required"
done

for required in cmd/main cmd/installer cmd/install_init cmd/install_callback \
    cmd/upgrade_init cmd/upgrade_callback cmd/uninstall_init cmd/uninstall_callback
do
    assert_executable_entry "$outer_modes" "$required" outer
done

tar -xf "$TARGET_PATH" -C "$VERIFY_DIR" || die 'Unable to extract the final FPK.'
app_tgz="$VERIFY_DIR/app.tgz"
[ -f "$app_tgz" ] || die 'The final FPK does not contain app.tgz.'

# fnpack derives the outer checksum from app.tgz, so the packaged manifest is
# the authority; the source manifest deliberately does not carry one.
packaged_checksum=$(manifest_value "$VERIFY_DIR/manifest" checksum)
app_tgz_checksum=$(md5sum "$app_tgz" | awk '{print $1}')
[ -n "$packaged_checksum" ] || die 'The packaged manifest does not declare checksum.'
[ "$packaged_checksum" = "$app_tgz_checksum" ] ||
    die "FPK manifest checksum does not match app.tgz (manifest=$packaged_checksum, app.tgz=$app_tgz_checksum)."

packaged_version=$(manifest_value "$VERIFY_DIR/manifest" version)
[ "$packaged_version" = "$version" ] ||
    die "Final FPK manifest is not version $version (found $packaged_version)."

nested_entries="$VERIFY_DIR/nested-entries.txt"
nested_modes="$VERIFY_DIR/nested-modes.txt"
tar -tzf "$app_tgz" | sed 's|^\./||' > "$nested_entries" || die 'Unable to list final app.tgz.'
tar -tvzf "$app_tgz" > "$nested_modes" || die 'Unable to inspect final app.tgz modes.'

# fnpack may append the outer config/ declarations into app.tgz, so assert the
# required payload entries without forbidding extras.
for required in docker/docker-compose.yaml docker/runtime-secrets/.keep \
    docker/scripts/postgres-healthcheck.sh docker/scripts/sub2api-entrypoint.sh \
    config/privilege config/resource ui/config LICENSE sub2api.sc
do
    grep -qx -- "$required" "$nested_entries" || die "Final app.tgz is missing: $required"
done

for required in docker/scripts/postgres-healthcheck.sh docker/scripts/sub2api-entrypoint.sh; do
    assert_executable_entry "$nested_modes" "$required" nested
done

# The packaged credential directory holds the database, Redis, JWT and TOTP
# secrets, so it must never ship group- or world-accessible.
secrets_mode=$(grep -E '[[:space:]]docker/runtime-secrets$' "$nested_modes" | head -n 1)
[ -n "$secrets_mode" ] || die 'Final app.tgz is missing docker/runtime-secrets.'
case "$secrets_mode" in
    drwx------*) ;;
    *) die "The packaged credential directory must stay private (0700): $secrets_mode" ;;
esac

artifact_bytes=$(stat -c '%s' "$TARGET_PATH")
artifact_sha256=$(sha256sum "$TARGET_PATH" | awk '{print $1}')
outer_count=$(wc -l < "$outer_entries" | tr -d '[:space:]')
nested_count=$(wc -l < "$nested_entries" | tr -d '[:space:]')

printf 'Artifact=%s\n' "$TARGET_PATH"
printf 'Bytes=%s\n' "$artifact_bytes"
printf 'SHA256=%s\n' "$artifact_sha256"
printf 'AppTgzChecksum=%s\n' "$app_tgz_checksum"
printf 'Version=%s\n' "$version"
printf 'Platform=%s\n' "$platform"
printf 'OuterEntries=%s\n' "$outer_count"
printf 'NestedEntries=%s\n' "$nested_count"
printf 'Result=passed\n'
