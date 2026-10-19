#!/bin/sh
# Build the deepseek-harness fnOS package (FPK) on a fnOS/Debian host.
#
# Native POSIX orchestrator. All source validation, checkout resolution, runtime
# construction and packaging steps run directly on fnOS/Debian; runtime lock
# data is parsed with Python 3.
#
# Scripts invoked from this directory:
#   test-package.sh          source contract tests (exit code 0 required)
#   resolve-upstream-source.sh  locked upstream source resolution
#   build-source-runtime.sh  locked upstream source build (bash)
#   package-linux.sh         fnpack staging and packaging (sh)
# plus the packaged fnpack resolver of the fnOS app-creator skill.
#
# The resolver validates commit and tree identity. Blob-level SHA-256 checks stay
# here: the "locked Git blobs" block hashes the contents of HEAD:pnpm-lock.yaml
# and HEAD:apps/cli/package.json, never their Git object IDs.
set -u

PROJECT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

usage() {
    cat <<'EOF'
Usage: build-fpk.sh [options]

Builds the deepseek-harness FPK from the locked upstream source on this host.

Options:
  --source-tree PATH       Use an explicit upstream checkout instead of the
                           pinned vendor/upstream/deepseek-harness submodule.
  --pnpm-tarball PATH      Use this locked pnpm tarball instead of the cache.
  --landlock-tarball PATH  Use this locked landlock-run tarball instead of the
                           cache.
  --pnpm-store-dir DIR     Reuse or populate this pnpm content-addressable store.
  --allow-download         Download the missing locked assets (upstream
                           submodule, pnpm tarball, landlock-run tarball).
  -h, --help               Show this help and exit.
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

SOURCE_TREE_ARG=''
PNPM_TARBALL_ARG=''
LANDLOCK_TARBALL_ARG=''
PNPM_STORE_DIR_ARG=''
ALLOW_DOWNLOAD=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --source-tree)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            SOURCE_TREE_ARG=$2
            shift 2
            ;;
        --pnpm-tarball)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            PNPM_TARBALL_ARG=$2
            shift 2
            ;;
        --landlock-tarball)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            LANDLOCK_TARBALL_ARG=$2
            shift 2
            ;;
        --pnpm-store-dir)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            PNPM_STORE_DIR_ARG=$2
            shift 2
            ;;
        --allow-download)
            ALLOW_DOWNLOAD=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            printf 'ERROR: unknown argument: %s\n' "$1" >&2
            exit 2
            ;;
    esac
done

# The packaging repository root owns .tmp and build; it is the
# parent of the parent of the package tree.
REPO_ROOT=$(CDPATH= cd -- "$PROJECT/../.." && pwd) ||
    die "Unable to resolve the packaging repository root above $PROJECT"

TMP_ROOT="$REPO_ROOT/.tmp"
BUILD_DIR="$REPO_ROOT/build"
MANIFEST_PATH="$PROJECT/manifest"
RUNTIME_LOCK_PATH="$PROJECT/runtime.lock.json"
SKILL_ROOT="$REPO_ROOT/.agents/skills/fnnas-app-creator"
FNPACK_RESOLVER="$SKILL_ROOT/scripts/resolve-fnpack.sh"
TEST_SCRIPT="$PROJECT/scripts/test-package.sh"
SOURCE_RESOLVER_SCRIPT="$PROJECT/scripts/resolve-upstream-source.sh"
SOURCE_BUILD_SCRIPT="$PROJECT/scripts/build-source-runtime.sh"
PACKAGE_SCRIPT="$PROJECT/scripts/package-linux.sh"
SUMMARY_CLIENT_CHECKER="$PROJECT/scripts/check-summary-client.mjs"

CACHE_DIR="$TMP_ROOT/deepseek-harness-runtime-cache"
DOWNLOAD_USER_AGENT='fn-pack-deepseek-harness-builder'

# Provenance components recorded in build-info.json, in this exact order.
BUILD_COMPONENT_PATHS='backend-ready.js
builtin-skills/dsh-maintenance/SKILL.md
builtin-skills/init/SKILL.md
builtin-skills/init/agents/openai.yaml
builtin-skills/skill-creator/SKILL.md
builtin-skills/skill-creator/references/openai_yaml.md
builtin-skills/skill-creator/references/powershell-authoring.md
builtin-skills/skill-creator/scripts/generate_openai_yaml.sh
builtin-skills/skill-creator/scripts/init_skill.sh
builtin-skills/skill-creator/scripts/quick_validate.sh
dsh-launcher
gateway-compat.js
gateway-proxy.js
gateway-websocket.js
pnpm-launcher
summary-client-compat.js
runtime.lock.json
select-loopback-port.js
pnpm/package.json
server/package.json
server/node_modules/@deepseek-ai/dsh/package.json
server/node_modules/@deepseek-ai/dsh/lib/bin.js'

# Runtime entries that must exist inside the final app.tgz, in addition to the
# ordered source patch artifacts that are appended at verification time.
REQUIRED_NESTED_ENTRIES='backend-ready.js
build-info.json
builtin-skills/dsh-maintenance/SKILL.md
builtin-skills/init/SKILL.md
builtin-skills/init/agents/openai.yaml
builtin-skills/skill-creator/SKILL.md
builtin-skills/skill-creator/references/openai_yaml.md
builtin-skills/skill-creator/references/powershell-authoring.md
builtin-skills/skill-creator/scripts/generate_openai_yaml.sh
builtin-skills/skill-creator/scripts/init_skill.sh
builtin-skills/skill-creator/scripts/quick_validate.sh
gateway-proxy.js
gateway-compat.js
gateway-websocket.js
summary-client-compat.js
dsh-launcher
pnpm-launcher
pnpm/bin/pnpm.cjs
pnpm/bin/pnpm.mjs
pnpm/dist/pnpm.mjs
runtime.lock.json
select-loopback-port.js
server/node_modules/@deepseek-ai/dsh/lib/bin.js
server/node_modules/@deepseek-ai/cordis-plugin-group/lib/index.js
server/node_modules/@deepseek-ai/node-addon-system-linux-x64/bin/landlock-run
server/node_modules/@deepseek-ai/node-addon-system-linux-x64/bin/glibc/system.node
server/node_modules/node-pty/prebuilds/linux-x64/pty.node
server/node_modules/yaml/dist/doc/directives.js
ui/config
ui/images/icon_64.png
THIRD_PARTY_NOTICES.md'

STAGE=''
TARGET_PATH=''
FINALIZED=0

cleanup() {
    if [ -n "$STAGE" ] && [ -d "$STAGE" ]; then
        rm -rf -- "$STAGE"
    fi
    # A versioned artifact that never finished verification is not a build
    # result; drop it so the next run starts from a clean directory.
    if [ "$FINALIZED" -eq 0 ] && [ -n "$TARGET_PATH" ] && [ -e "$TARGET_PATH" ]; then
        rm -f -- "$TARGET_PATH"
    fi
    return 0
}
trap cleanup EXIT HUP INT TERM

# --- helpers -----------------------------------------------------------------
require_command() {
    command -v "$1" >/dev/null 2>&1 || die "$2"
}

require_file() {
    [ -e "$1" ] || die "$2"
}

bytes_of() {
    stat -c '%s' "$1"
}

sha256_of() {
    sha256sum "$1" | awk '{print $1}'
}

count_lines() {
    sed '/^$/d' | wc -l | tr -d ' '
}

join_comma() {
    tr '\n' ',' | sed -e 's/,$//' -e 's/,/, /g'
}

json_field() {
    # json_field <file> <python-expression-over-data>
    python3 -c '
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
value = eval(sys.argv[2], {"__builtins__": {"len": len, "str": str, "int": int, "sum": sum}}, {"data": data})
if isinstance(value, bool):
    print("true" if value else "false")
elif value is None:
    print("")
else:
    print(value)
' "$1" "$2"
}

lock_field() {
    # lock_field <python-expression-over-the-runtime-lock>
    python3 -c '
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    lock = json.load(handle)
value = eval(sys.argv[2], {"__builtins__": {"len": len, "str": str, "int": int}}, {"lock": lock})
if value is None:
    raise SystemExit("missing runtime lock field: " + sys.argv[2])
print(value)
' "$RUNTIME_LOCK_PATH" "$1"
}

manifest_value() {
    # manifest_value <key>: first "key = value" line wins, trailing comment and
    # whitespace stripped, matching the fnOS manifest parser.
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$MANIFEST_PATH" |
        head -n 1 |
        sed -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//'
}

manifest_field_pairs() {
    # manifest_field_pairs <manifest>: "key=value" records; invalid lines fail.
    _pairs_path=$1
    while IFS= read -r _pairs_line || [ -n "$_pairs_line" ]; do
        _pairs_trimmed=${_pairs_line#"${_pairs_line%%[![:space:]]*}"}
        case "$_pairs_trimmed" in
            ''|'#'*) continue ;;
        esac
        case "$_pairs_trimmed" in
            *=*) ;;
            *) die "Manifest contains an invalid line: $_pairs_path" ;;
        esac
        _pairs_key=${_pairs_trimmed%%=*}
        _pairs_value=${_pairs_trimmed#*=}
        _pairs_key=${_pairs_key%"${_pairs_key##*[![:space:]]}"}
        _pairs_value=${_pairs_value#"${_pairs_value%%[![:space:]]*}"}
        _pairs_value=${_pairs_value%"${_pairs_value##*[![:space:]]}"}
        case "$_pairs_key" in
            ''|*[!A-Za-z0-9_]*) die "Manifest contains an invalid line: $_pairs_path" ;;
        esac
        printf '%s=%s\n' "$_pairs_key" "$_pairs_value"
    done < "$_pairs_path"
    return 0
}

elf_machine_check() {
    # elf_machine_check <file> <expected-machine>: 64-bit little-endian ELF only.
    _elf_file=$1
    _elf_expected=$2
    [ -f "$_elf_file" ] || die "Expected an ELF file: $_elf_file"
    _elf_magic=$(od -An -tx1 -N4 "$_elf_file" | tr -d ' \n')
    [ "$_elf_magic" = '7f454c46' ] || die "Expected an ELF file: $_elf_file"
    _elf_class=$(od -An -tu1 -j4 -N1 "$_elf_file" | tr -d ' ')
    _elf_order=$(od -An -tu1 -j5 -N1 "$_elf_file" | tr -d ' ')
    [ "$_elf_class" = '2' ] && [ "$_elf_order" = '1' ] ||
        die "Expected a 64-bit little-endian ELF file: $_elf_file"
    _elf_machine=$(od -An -tu2 -j18 -N2 "$_elf_file" | awk '{print $1 + 0}')
    [ "$_elf_machine" = "$_elf_expected" ] ||
        die "Unexpected ELF machine $_elf_machine in $_elf_file; expected $_elf_expected"
}

build_component() {
    # build_component <root> <relative-path>: one "path|bytes|sha256" record.
    _component_root=$1
    _component_rel=$2
    _component_native="$_component_root/$_component_rel"
    [ -f "$_component_native" ] ||
        die "Build provenance component is missing: $_component_rel"
    _component_bytes=$(bytes_of "$_component_native")
    _component_sha256=$(sha256_of "$_component_native")
    printf '%s|%s|%s\n' "$_component_rel" "$_component_bytes" "$_component_sha256"
}

remove_safe_tree() {
    # remove_safe_tree <path> <allowed-root>: refuse to delete outside the root.
    _remove_target=$1
    _remove_root=$2
    [ -e "$_remove_target" ] || return 0
    _remove_resolved_root=$(CDPATH= cd -- "$_remove_root" && pwd -P) ||
        die "Unsafe recursive removal root: $_remove_root"
    _remove_resolved_target=$(CDPATH= cd -- "$_remove_target" && pwd -P) ||
        die "Unsafe recursive removal target: $_remove_target"
    case "$_remove_resolved_target/" in
        "$_remove_resolved_root"/*) ;;
        *) die "Unsafe recursive removal target: $_remove_resolved_target" ;;
    esac
    rm -rf -- "$_remove_resolved_target"
}

tar_mode_table() {
    # stdin: "tar -tvf" output; stdout: "<mode><TAB><name>" with "./" stripped.
    awk '{
        mode = $1
        name = $6
        for (i = 7; i <= NF; i++) name = name " " $i
        sub(/^\.\//, "", name)
        printf "%s\t%s\n", mode, name
    }'
}

require_tar_entry() {
    # require_tar_entry <listing> <entry> <message-prefix>
    _entry_listing=$1
    _entry_name=$2
    _entry_prefix=$3
    if grep -qxF -- "$_entry_name" "$_entry_listing" ||
        grep -qxF -- "$_entry_name/" "$_entry_listing"; then
        return 0
    fi
    die "$_entry_prefix: $_entry_name"
}

download_asset() {
    # download_asset <url> <destination> <label>
    _download_url=$1
    _download_destination=$2
    _download_label=$3
    _download_partial="${_download_destination}.partial"
    rm -f -- "$_download_partial"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --user-agent "$DOWNLOAD_USER_AGENT" --output "$_download_partial" -- "$_download_url" ||
            die "Unable to download the $_download_label: $_download_url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q --user-agent="$DOWNLOAD_USER_AGENT" --output-document="$_download_partial" "$_download_url" ||
            die "Unable to download the $_download_label: $_download_url"
    else
        die 'curl or wget is required to download the locked runtime assets.'
    fi
    mv -f -- "$_download_partial" "$_download_destination"
}

resolve_locked_asset() {
    # resolve_locked_asset <explicit-path> <cache-path> <url> <label> <option>
    _asset_explicit=$1
    _asset_cache=$2
    _asset_url=$3
    _asset_label=$4
    _asset_option=$5
    if [ -n "$_asset_explicit" ]; then
        [ -f "$_asset_explicit" ] ||
            die "The $_asset_label tarball does not exist: $_asset_explicit"
    elif [ -f "$_asset_cache" ]; then
        _asset_explicit=$_asset_cache
    elif [ "$ALLOW_DOWNLOAD" -eq 1 ]; then
        mkdir -p "$CACHE_DIR"
        download_asset "$_asset_url" "$_asset_cache" "$_asset_label tarball"
        _asset_explicit=$_asset_cache
    else
        die "The locked $_asset_label tarball is unavailable. Pass $_asset_option or explicitly use --allow-download. Expected cache: $_asset_cache"
    fi
    RESOLVED_ASSET=$(CDPATH= cd -- "$(dirname -- "$_asset_explicit")" && pwd -P)/$(basename -- "$_asset_explicit") ||
        die "Unable to resolve the $_asset_label tarball: $_asset_explicit"
    printf '%s\n' "$RESOLVED_ASSET"
}

verify_asset_integrity() {
    # verify_asset_integrity <file> <sha256> <integrity> <label>
    _integrity_file=$1
    _integrity_sha256=$2
    _integrity_expected=$3
    _integrity_label=$4
    _integrity_actual=$(sha256_of "$_integrity_file")
    [ "$_integrity_actual" = "$_integrity_sha256" ] ||
        die "$_integrity_label SHA-256 mismatch. Expected $_integrity_sha256, got $_integrity_actual"
    _integrity_sha512=$(sha512sum "$_integrity_file" | awk '{print $1}')
    _integrity_value=$(python3 -c 'import base64, binascii, sys; print("sha512-" + base64.b64encode(binascii.unhexlify(sys.argv[1])).decode())' "$_integrity_sha512") ||
        die "Unable to compute the SHA-512 integrity of $_integrity_file"
    [ "$_integrity_value" = "$_integrity_expected" ] ||
        die "$_integrity_label integrity mismatch. Expected $_integrity_expected, got $_integrity_value"
}

# --- preconditions -----------------------------------------------------------
require_command python3 'python3 is required to read runtime.lock.json.'
require_command tar 'tar is required to inspect the locked assets and the FPK.'
require_command sha256sum 'sha256sum is required to verify the locked runtime assets.'
require_command sha512sum 'sha512sum is required to verify the locked runtime asset integrity.'
require_command od 'od is required to inspect ELF headers.'
require_command stat 'stat is required to measure build inputs and the artifact.'
require_command git 'git is required to inspect and archive the locked upstream source.'
require_command bash 'bash is required to run the locked source build script.'
require_command node 'node is required to validate the packaged summary client adapter.'
require_command mktemp 'mktemp is required to create the staging directory.'
require_command find 'find is required to inspect the generated runtime.'
require_command awk 'awk is required to parse tool output.'

printf 'Project=%s\n' "$PROJECT"
printf 'RepositoryRoot=%s\n' "$REPO_ROOT"

require_file "$FNPACK_RESOLVER" 'The bundled fnpack resolver is missing.'
require_file "$RUNTIME_LOCK_PATH" 'runtime.lock.json is missing.'
require_file "$MANIFEST_PATH" 'The package manifest is missing.'
require_file "$TEST_SCRIPT" "The native source validation script is missing: $TEST_SCRIPT"
require_file "$SOURCE_RESOLVER_SCRIPT" "The POSIX upstream source resolver is missing: $SOURCE_RESOLVER_SCRIPT"
require_file "$SOURCE_BUILD_SCRIPT" "The locked source build script is missing: $SOURCE_BUILD_SCRIPT"
require_file "$PACKAGE_SCRIPT" "The Linux packaging script is missing: $PACKAGE_SCRIPT"
require_file "$SUMMARY_CLIENT_CHECKER" "The shared summary client compatibility checker is missing: $SUMMARY_CLIENT_CHECKER"

# --- source contract tests ---------------------------------------------------
sh "$TEST_SCRIPT" || die 'Source validation failed before build.'

# --- runtime lock structure --------------------------------------------------
_lock_shape=$(python3 - "$RUNTIME_LOCK_PATH" <<'PY' 2>&1
import json, sys

with open(sys.argv[1], encoding="utf-8") as handle:
    lock = json.load(handle)

patches = lock.get("source_patches")
if (lock.get("schema") != 5
        or not isinstance(patches, list)
        or len(patches) != 4
        or any(not isinstance(entry, dict) for entry in patches)
        or not isinstance(lock.get("pnpm"), dict)
        or not isinstance(lock.get("landlock_run"), dict)):
    raise SystemExit("runtime.lock.json must use schema 5 and contain four ordered source_patches plus pnpm and landlock_run objects.")
PY
) || die "$_lock_shape"

LOCK_UPSTREAM_REPOSITORY=$(lock_field 'lock["upstream_repository"]') ||
    die 'Unable to read upstream_repository from runtime.lock.json.'
LOCK_UPSTREAM_COMMIT=$(lock_field 'lock["upstream_commit"]') ||
    die 'Unable to read upstream_commit from runtime.lock.json.'
LOCK_UPSTREAM_TREE=$(lock_field 'lock["upstream_tree"]') ||
    die 'Unable to read upstream_tree from runtime.lock.json.'
LOCK_PNPM_LOCK_SHA256=$(lock_field 'lock["pnpm_lock_sha256"]') ||
    die 'Unable to read pnpm_lock_sha256 from runtime.lock.json.'
LOCK_CLI_PACKAGE_SHA256=$(lock_field 'lock["cli_package_sha256"]') ||
    die 'Unable to read cli_package_sha256 from runtime.lock.json.'
LOCK_DSH_VERSION=$(lock_field 'lock["dsh_version"]') ||
    die 'Unable to read dsh_version from runtime.lock.json.'
LOCK_NODE_ENGINES=$(lock_field 'lock["node_engines"]') ||
    die 'Unable to read node_engines from runtime.lock.json.'
LOCK_TARGET=$(lock_field 'lock["target"]') ||
    die 'Unable to read target from runtime.lock.json.'
LOCK_PLATFORM=$(lock_field 'lock["platform"]') ||
    die 'Unable to read platform from runtime.lock.json.'
LOCK_ELF_MACHINE=$(lock_field 'lock["elf_machine"]') ||
    die 'Unable to read elf_machine from runtime.lock.json.'
LOCK_PNPM_VERSION=$(lock_field 'lock["pnpm"]["version"]') ||
    die 'Unable to read the locked pnpm version.'
LOCK_PNPM_ASSET_NAME=$(lock_field 'lock["pnpm"]["asset_name"]') ||
    die 'Unable to read the locked pnpm asset name.'
LOCK_PNPM_ASSET_URL=$(lock_field 'lock["pnpm"]["asset_url"]') ||
    die 'Unable to read the locked pnpm asset URL.'
LOCK_PNPM_ASSET_SHA256=$(lock_field 'lock["pnpm"]["asset_sha256"]') ||
    die 'Unable to read the locked pnpm asset hash.'
LOCK_PNPM_INTEGRITY=$(lock_field 'lock["pnpm"]["integrity"]') ||
    die 'Unable to read the locked pnpm integrity.'
LOCK_LANDLOCK_PACKAGE_NAME=$(lock_field 'lock["landlock_run"]["package_name"]') ||
    die 'Unable to read the locked landlock-run package name.'
LOCK_LANDLOCK_VERSION=$(lock_field 'lock["landlock_run"]["version"]') ||
    die 'Unable to read the locked landlock-run version.'
LOCK_LANDLOCK_ASSET_NAME=$(lock_field 'lock["landlock_run"]["asset_name"]') ||
    die 'Unable to read the locked landlock-run asset name.'
LOCK_LANDLOCK_ASSET_URL=$(lock_field 'lock["landlock_run"]["asset_url"]') ||
    die 'Unable to read the locked landlock-run asset URL.'
LOCK_LANDLOCK_ASSET_SHA256=$(lock_field 'lock["landlock_run"]["asset_sha256"]') ||
    die 'Unable to read the locked landlock-run asset hash.'
LOCK_LANDLOCK_INTEGRITY=$(lock_field 'lock["landlock_run"]["integrity"]') ||
    die 'Unable to read the locked landlock-run integrity.'
LOCK_LANDLOCK_BINARY_PATH=$(lock_field 'lock["landlock_run"]["binary_path"]') ||
    die 'Unable to read the locked landlock-run binary path.'

# --- manifest identity -------------------------------------------------------
app_name=$(manifest_value appname)
version=$(manifest_value version)
[ -n "$app_name" ] && [ -n "$version" ] ||
    die 'The manifest must contain parseable appname and version fields.'
case "$app_name-$version" in
    *[!A-Za-z0-9._-]*) die "The manifest appname or version is not a usable artifact name: $app_name-$version" ;;
esac

[ "$LOCK_PLATFORM" = 'x86' ] || die "Unsupported locked package platform: $LOCK_PLATFORM"
TARGET_PATH="$BUILD_DIR/${app_name}_${version}_${LOCK_PLATFORM}.fpk"
mkdir -p "$TMP_ROOT" "$BUILD_DIR"
[ -e "$TARGET_PATH" ] && die "Refusing to overwrite existing artifact: $TARGET_PATH"

STAGE=$(mktemp -d "$TMP_ROOT/deepseek-harness-build.XXXXXX") ||
    die "Unable to create a staging directory below $TMP_ROOT"

PACKAGE_STAGE="$STAGE/package"
PNPM_STAGE="$STAGE/pnpm"
LANDLOCK_STAGE="$STAGE/landlock"
VERIFY_STAGE="$STAGE/verify"
VERIFY_APP_STAGE="$STAGE/verify-app"
ARTIFACT_STAGE="$STAGE/artifact"
SOURCE_ARCHIVE="$STAGE/deepseek-harness-source.tar"
SOURCE_RUNTIME_ARCHIVE="$STAGE/deepseek-harness-runtime.tgz"
PATCH_LIST="$STAGE/source-patches.txt"
mkdir -p "$PACKAGE_STAGE" "$PNPM_STAGE" "$LANDLOCK_STAGE" "$VERIFY_STAGE" \
    "$VERIFY_APP_STAGE" "$ARTIFACT_STAGE"

# --- upstream source ---------------------------------------------------------
# resolve-upstream-source.sh --repository-root DIR --expected-repository URL
#   --expected-commit SHA --expected-tree SHA [--source-tree DIR] [--allow-download]
# and reports "Path=", "Kind=", "Repository=", "Commit=" and "Tree=" on stdout.
set -- --repository-root "$REPO_ROOT" \
    --expected-repository "$LOCK_UPSTREAM_REPOSITORY" \
    --expected-commit "$LOCK_UPSTREAM_COMMIT" \
    --expected-tree "$LOCK_UPSTREAM_TREE"
if [ -n "$SOURCE_TREE_ARG" ]; then
    set -- "$@" --source-tree "$SOURCE_TREE_ARG"
fi
if [ "$ALLOW_DOWNLOAD" -eq 1 ]; then
    set -- "$@" --allow-download
fi
_resolver_output=$(sh "$SOURCE_RESOLVER_SCRIPT" "$@") ||
    die 'Upstream source resolution failed.'
printf '%s\n' "$_resolver_output" > "$STAGE/resolver-output.txt"

RESOLVED_SOURCE=''
RESOLVED_KIND=''
RESOLVED_REMOTE=''
RESOLVED_COMMIT=''
RESOLVED_TREE=''
while IFS= read -r _resolver_line; do
    case "$_resolver_line" in
        Path=*) RESOLVED_SOURCE=${_resolver_line#Path=} ;;
        Kind=*) RESOLVED_KIND=${_resolver_line#Kind=} ;;
        Repository=*) RESOLVED_REMOTE=${_resolver_line#Repository=} ;;
        Commit=*) RESOLVED_COMMIT=${_resolver_line#Commit=} ;;
        Tree=*) RESOLVED_TREE=${_resolver_line#Tree=} ;;
    esac
done < "$STAGE/resolver-output.txt"
[ -n "$RESOLVED_SOURCE" ] && [ -n "$RESOLVED_KIND" ] && [ -n "$RESOLVED_REMOTE" ] &&
    [ -n "$RESOLVED_COMMIT" ] && [ -n "$RESOLVED_TREE" ] ||
    die 'resolve-upstream-source.sh did not report the resolved source checkout.'
printf 'SourceKind=%s\n' "$RESOLVED_KIND"
printf 'SourcePath=%s\n' "$RESOLVED_SOURCE"
printf 'SourceCommit=%s\n' "$RESOLVED_COMMIT"
printf 'SourceTree=%s\n' "$RESOLVED_TREE"

# --- locked Git blobs --------------------------------------------------------
# Hash the content of the blob pointed at by HEAD:<path>; the object ID itself
# is never hashed.
_git_blob_error="$STAGE/git-blob.err"
git -C "$RESOLVED_SOURCE" cat-file blob HEAD:pnpm-lock.yaml > "$STAGE/blob-pnpm-lock.yaml" 2>"$_git_blob_error" ||
    die "Unable to read locked Git blob HEAD:pnpm-lock.yaml: $(cat "$_git_blob_error")"
git -C "$RESOLVED_SOURCE" cat-file blob HEAD:apps/cli/package.json > "$STAGE/blob-cli-package.json" 2>"$_git_blob_error" ||
    die "Unable to read locked Git blob HEAD:apps/cli/package.json: $(cat "$_git_blob_error")"

_source_pnpm_lock_hash=$(sha256_of "$STAGE/blob-pnpm-lock.yaml")
_source_cli_package_hash=$(sha256_of "$STAGE/blob-cli-package.json")
[ "$_source_pnpm_lock_hash" = "$LOCK_PNPM_LOCK_SHA256" ] ||
    die "Official pnpm-lock.yaml hash mismatch: $_source_pnpm_lock_hash"
[ "$_source_cli_package_hash" = "$LOCK_CLI_PACKAGE_SHA256" ] ||
    die "Official apps/cli/package.json hash mismatch: $_source_cli_package_hash"

git -C "$RESOLVED_SOURCE" show HEAD:apps/cli/package.json > "$STAGE/cli-package.json" 2>"$_git_blob_error" ||
    die "Unable to read the locked CLI manifest: $(cat "$_git_blob_error")"
git -C "$RESOLVED_SOURCE" show HEAD:package.json > "$STAGE/root-package.json" 2>"$_git_blob_error" ||
    die "Unable to read the locked root manifest: $(cat "$_git_blob_error")"

_cli_name=$(json_field "$STAGE/cli-package.json" 'data["name"]')
_cli_version=$(json_field "$STAGE/cli-package.json" 'data["version"]')
[ "$_cli_name" = '@deepseek-ai/dsh' ] && [ "$_cli_version" = "$LOCK_DSH_VERSION" ] ||
    die "Unexpected official DSH identity: $_cli_name@$_cli_version"
_root_package_manager=$(json_field "$STAGE/root-package.json" 'data["packageManager"]')
[ "$_root_package_manager" = "pnpm@$LOCK_PNPM_VERSION" ] ||
    die "Official source requires $_root_package_manager, but the runtime lock selects pnpm@$LOCK_PNPM_VERSION"
_root_node_engines=$(json_field "$STAGE/root-package.json" 'data["engines"]["node"]')
[ "$_root_node_engines" = "$LOCK_NODE_ENGINES" ] ||
    die "Official Node engine mismatch: $_root_node_engines"

# --- ordered source patches --------------------------------------------------
# The order, the artifact paths and the test targets are the build contract
# carried over from the PowerShell original.
_patch_shape=$(python3 - "$RUNTIME_LOCK_PATH" "$STAGE/patch-lock.txt" 2>&1 <<'PY'
import json, re, sys

expected = [
    ("patches/0002-dsh-plugin-profile-scoped-management.patch",
     "source-patches/0002-dsh-plugin-profile-scoped-management.patch",
     "packages/boot/plugin-manager/tests/operations.spec.ts"),
    ("patches/0004-web-app-private-auth-token-handoff.patch",
     "source-patches/0004-web-app-private-auth-token-handoff.patch",
     "packages/bundle/web-app/tests/web-app.spec.ts"),
    ("patches/0007-attachment-storage-respect-access-boundary.patch",
     "source-patches/0007-attachment-storage-respect-access-boundary.patch",
     "packages/attachment/attachment-local/tests/store.spec.ts"),
    ("patches/0008-fnos-transport-defaults.patch",
     "source-patches/0008-fnos-transport-defaults.patch",
     "packages/api/gateway/tests/gateway-stream.host.spec.ts packages/client/connection/tests/recovery-config.client.spec.ts"),
]

with open(sys.argv[1], encoding="utf-8") as handle:
    lock = json.load(handle)

locks = lock["source_patches"]
records = []
for index, (expected_path, expected_artifact, expected_test_target) in enumerate(expected):
    entry = locks[index]
    sha256 = entry.get("sha256")
    if (entry.get("path") != expected_path
            or entry.get("artifact_path") != expected_artifact
            or not isinstance(sha256, str)
            or re.fullmatch(r"[0-9a-f]{64}", sha256) is None
            or entry.get("test_target") != expected_test_target):
        raise SystemExit("runtime.lock.json contains an invalid or out-of-order source patch lock at index %d." % index)
    records.append((expected_path, expected_artifact, sha256, expected_test_target))

with open(sys.argv[2], "w", encoding="utf-8") as handle:
    for record in records:
        handle.write("%s|%s|%s|%s\n" % record)
PY
) || die "$_patch_shape"

: > "$PATCH_LIST"
while IFS='|' read -r _patch_rel _patch_artifact _patch_sha256 _patch_test_target; do
    [ -n "$_patch_rel" ] || continue
    case "$_patch_sha256$_patch_artifact" in
        *[!A-Za-z0-9._/@-]*) die "Locked source patch entry is not usable: $_patch_artifact" ;;
    esac
    _patch_path="$PROJECT/$_patch_rel"
    [ -f "$_patch_path" ] || die "Locked source patch is unavailable: $_patch_path"
    _patch_actual=$(sha256_of "$_patch_path")
    [ "$_patch_actual" = "$_patch_sha256" ] ||
        die "Source patch SHA-256 mismatch. Expected $_patch_sha256, got $_patch_actual"
    printf '%s|%s|%s|%s\n' "$_patch_rel" "$_patch_artifact" "$_patch_actual" "$_patch_test_target" >> "$PATCH_LIST"
done < "$STAGE/patch-lock.txt"
_patch_count=$(count_lines < "$PATCH_LIST")
[ "$_patch_count" -eq 4 ] || die "Expected four locked source patches, got $_patch_count."

# --- source-only runtime marker ---------------------------------------------
MARKER_PATH_REL='app/server/package.json'
_marker_native="$PROJECT/$MARKER_PATH_REL"
[ -f "$_marker_native" ] || die "Build provenance component is missing: $MARKER_PATH_REL"
_marker_name=$(json_field "$_marker_native" 'data["name"]')
_marker_dependency=$(json_field "$_marker_native" 'data["dependencies"]["@deepseek-ai/dsh"]')
[ "$_marker_name" = 'deepseek-harness-fnos-runtime-marker' ] &&
    [ "$_marker_dependency" = "$LOCK_DSH_VERSION" ] ||
    die 'app/server/package.json must remain a source-only marker for the locked DSH runtime.'
MARKER_BYTES=$(bytes_of "$_marker_native")
MARKER_SHA256=$(sha256_of "$_marker_native")

# --- locked runtime assets ---------------------------------------------------
resolved_pnpm=$(resolve_locked_asset "$PNPM_TARBALL_ARG" \
    "$CACHE_DIR/$LOCK_PNPM_ASSET_NAME" "$LOCK_PNPM_ASSET_URL" 'pnpm' '--pnpm-tarball') ||
    die 'Unable to resolve the locked pnpm tarball.'
resolved_landlock=$(resolve_locked_asset "$LANDLOCK_TARBALL_ARG" \
    "$CACHE_DIR/$LOCK_LANDLOCK_ASSET_NAME" "$LOCK_LANDLOCK_ASSET_URL" 'landlock-run' '--landlock-tarball') ||
    die 'Unable to resolve the locked landlock-run tarball.'
verify_asset_integrity "$resolved_pnpm" "$LOCK_PNPM_ASSET_SHA256" "$LOCK_PNPM_INTEGRITY" 'pnpm tarball'
verify_asset_integrity "$resolved_landlock" "$LOCK_LANDLOCK_ASSET_SHA256" "$LOCK_LANDLOCK_INTEGRITY" 'landlock-run tarball'
printf 'PnpmTarball=%s\n' "$resolved_pnpm"
printf 'LandlockTarball=%s\n' "$resolved_landlock"

# --- staging tree ------------------------------------------------------------
for directory in app cmd config wizard; do
    cp -R -- "$PROJECT/$directory" "$PACKAGE_STAGE/$directory" ||
        die "Unable to stage the package directory: $directory"
done
for file in manifest ICON.PNG ICON_256.PNG; do
    cp -- "$PROJECT/$file" "$PACKAGE_STAGE/$file" ||
        die "Unable to stage the package file: $file"
done
cp -- "$PROJECT/THIRD_PARTY_NOTICES.md" "$PACKAGE_STAGE/app/THIRD_PARTY_NOTICES.md" ||
    die 'Unable to stage THIRD_PARTY_NOTICES.md.'
cp -- "$RUNTIME_LOCK_PATH" "$PACKAGE_STAGE/app/runtime.lock.json" ||
    die 'Unable to stage runtime.lock.json.'
# The source tree carries restrictive directory modes that the copy may keep on
# this filesystem; the staging tree is extended below with the generated
# runtime, so make it writable regardless of the inherited modes.
chmod -R u+rwX "$PACKAGE_STAGE" || die 'Unable to normalize the staging tree modes.'

while IFS='|' read -r _patch_rel _patch_artifact _patch_sha256 _patch_test_target; do
    [ -n "$_patch_artifact" ] || continue
    _staged_patch="$PACKAGE_STAGE/app/$_patch_artifact"
    mkdir -p -- "$(dirname -- "$_staged_patch")" ||
        die "Unable to create the staged patch directory for $_patch_artifact"
    cp -- "$PROJECT/$_patch_rel" "$_staged_patch" ||
        die "Unable to stage the locked source patch: $_patch_artifact"
done < "$PATCH_LIST"

# --- landlock-run asset ------------------------------------------------------
tar -tvzf "$resolved_landlock" > "$STAGE/landlock-modes.raw" ||
    die 'Unable to list the locked landlock-run tarball.'
tar_mode_table < "$STAGE/landlock-modes.raw" > "$STAGE/landlock-modes.txt"
_landlock_archive_binary="package/$LOCK_LANDLOCK_BINARY_PATH"
_landlock_archive_modes=$(awk -F'\t' -v target="$_landlock_archive_binary" '$2 == target { print $1 }' "$STAGE/landlock-modes.txt")
_landlock_archive_mode_count=$(printf '%s\n' "$_landlock_archive_modes" | count_lines)
[ "$_landlock_archive_mode_count" -eq 1 ] ||
    die "The locked landlock-run tarball does not contain one executable $_landlock_archive_binary entry."
_landlock_archive_entry_mode=$(printf '%s\n' "$_landlock_archive_modes" | sed '/^$/d' | head -n 1)
case "$_landlock_archive_entry_mode" in
    -??x*) ;;
    *) die "The locked landlock-run tarball does not contain one executable $_landlock_archive_binary entry." ;;
esac

tar -xzf "$resolved_landlock" -C "$LANDLOCK_STAGE" ||
    die 'Unable to extract the locked landlock-run tarball.'
landlock_package_root="$LANDLOCK_STAGE/package"
[ -d "$landlock_package_root" ] ||
    die 'The locked landlock-run tarball does not contain a package directory.'
official_landlock_path="$landlock_package_root/$LOCK_LANDLOCK_BINARY_PATH"
official_flock_path="$landlock_package_root/bin/glibc/system.node"
[ -f "$official_landlock_path" ] ||
    die "The locked landlock-run binary is missing: $LOCK_LANDLOCK_BINARY_PATH"
[ -f "$official_flock_path" ] || die 'The locked landlock-run flock addon is missing.'
[ -f "$landlock_package_root/package.json" ] ||
    die 'The locked landlock-run package manifest is missing.'
[ -f "$landlock_package_root/prebuilds.json" ] ||
    die 'The locked landlock-run prebuild declaration is missing.'

_landlock_shape=$(python3 - "$landlock_package_root/package.json" "$landlock_package_root/prebuilds.json" \
    "$LOCK_LANDLOCK_PACKAGE_NAME" "$LOCK_LANDLOCK_VERSION" "$LOCK_LANDLOCK_BINARY_PATH" 2>&1 <<'PY'
import json, sys

package_path, prebuilds_path, expected_name, expected_version, expected_binary = sys.argv[1:6]
with open(package_path, encoding="utf-8") as handle:
    package = json.load(handle)
with open(prebuilds_path, encoding="utf-8") as handle:
    prebuilds = json.load(handle)

if (package.get("name") != expected_name
        or package.get("version") != expected_version
        or "linux" not in (package.get("os") or [])
        or "x64" not in (package.get("cpu") or [])):
    raise SystemExit("Unexpected landlock-run package identity %s@%s" % (package.get("name"), package.get("version")))

declared = [entry for entry in (prebuilds.get("binaries") or [])
            if entry.get("tool") == "landlock-run"
            and entry.get("kind") == "static-musl"
            and entry.get("path") == expected_binary]
if prebuilds.get("platform") != "linux-x64" or len(declared) != 1:
    raise SystemExit("The official landlock-run prebuild declaration does not match linux-x64 static-musl.")
PY
) || die "$_landlock_shape"

# The published 0.1.2 package predates the official GitHub organization rename.
# Normalize only that repository URL; every other package field and the complete
# prebuild declaration must still match the locked Git source.
_source_landlock_root="$RESOLVED_SOURCE/native/system/packages/linux-x64"
for metadata_file in package.json prebuilds.json; do
    [ -f "$_source_landlock_root/$metadata_file" ] ||
        die "Official landlock-run metadata is missing from the locked source: $_source_landlock_root/$metadata_file"
done
_landlock_metadata=$(python3 - "$_source_landlock_root/package.json" "$landlock_package_root/package.json" 2>&1 <<'PY'
import json, sys

with open(sys.argv[1], encoding="utf-8") as handle:
    source = json.load(handle)
with open(sys.argv[2], encoding="utf-8") as handle:
    asset = json.load(handle)
allowed = {
    "git+https://github.com/deepseek-ai/deepseek-harness.git",
    "git+https://github.com/deepseek-harness/deepseek-harness.git",
}
source_url = (source.get("repository") or {}).get("url")
asset_url = (asset.get("repository") or {}).get("url")
if source_url not in allowed or asset_url not in allowed:
    raise SystemExit("unexpected repository URL in official system package metadata")
source["repository"]["url"] = "OFFICIAL_REPOSITORY"
asset["repository"]["url"] = "OFFICIAL_REPOSITORY"
if source != asset:
    raise SystemExit("package.json differs beyond the official repository organization rename")
PY
) || die "Official landlock-run asset metadata differs from the locked Git source: $_landlock_metadata"
cmp -s "$_source_landlock_root/prebuilds.json" "$landlock_package_root/prebuilds.json" ||
    die 'Official landlock-run asset metadata differs from the locked Git source: prebuilds.json'

elf_machine_check "$official_landlock_path" "$LOCK_ELF_MACHINE"
official_landlock_hash=$(sha256_of "$official_landlock_path")

# --- host architecture -------------------------------------------------------
host_architecture=$(uname -m)
[ "$host_architecture" = 'x86_64' ] ||
    die "This build host is not x86-64: $host_architecture"

# --- locked source build -----------------------------------------------------
git -C "$RESOLVED_SOURCE" archive --format=tar --output="$SOURCE_ARCHIVE" "$RESOLVED_COMMIT" ||
    die 'Unable to archive the locked official source commit.'

# build-source-runtime.sh <source.tar> <pnpm.tgz> <landlock.tgz> <runtime.tgz>
#   <source-commit> <dsh-version> (<source.patch> <patch-sha256> <test-target>)...
set -- "$SOURCE_ARCHIVE" "$resolved_pnpm" "$resolved_landlock" "$SOURCE_RUNTIME_ARCHIVE" \
    "$RESOLVED_COMMIT" "$LOCK_DSH_VERSION"
while IFS='|' read -r _patch_rel _patch_artifact _patch_sha256 _patch_test_target; do
    [ -n "$_patch_rel" ] || continue
    set -- "$@" "$PROJECT/$_patch_rel" "$_patch_sha256" "$_patch_test_target"
done < "$PATCH_LIST"
if [ -n "$PNPM_STORE_DIR_ARG" ]; then
    env DSH_PNPM_STORE_DIR="$PNPM_STORE_DIR_ARG" bash "$SOURCE_BUILD_SCRIPT" "$@" ||
        die 'Official DeepSeek Harness source build failed.'
else
    bash "$SOURCE_BUILD_SCRIPT" "$@" ||
        die 'Official DeepSeek Harness source build failed.'
fi

# --- generated runtime -------------------------------------------------------
STAGED_SERVER="$PACKAGE_STAGE/app/server"
remove_safe_tree "$STAGED_SERVER" "$PACKAGE_STAGE"
mkdir -p "$STAGED_SERVER"
tar -xzf "$SOURCE_RUNTIME_ARCHIVE" -C "$STAGED_SERVER" ||
    die 'Unable to extract the generated source runtime.'

dsh_package_path="$STAGED_SERVER/node_modules/@deepseek-ai/dsh/package.json"
[ -f "$dsh_package_path" ] || die "Built DSH package is missing: $dsh_package_path"
dsh_package_version=$(json_field "$dsh_package_path" 'data["version"]')
[ "$dsh_package_version" = "$LOCK_DSH_VERSION" ] ||
    die "Built DSH version mismatch: $dsh_package_version"

runtime_manifest="$STAGED_SERVER/package.json"
[ -f "$runtime_manifest" ] || die 'The generated source runtime manifest is missing.'
_runtime_manifest_name=$(json_field "$runtime_manifest" 'data["name"]')
_runtime_manifest_has_dsh=$(json_field "$runtime_manifest" '"@deepseek-ai/dsh" in data["dependencies"]')
runtime_dep_count=$(json_field "$runtime_manifest" 'len(data["dependencies"])')
[ "$_runtime_manifest_name" = 'dsh-fnos-runtime' ] &&
    [ "$_runtime_manifest_has_dsh" = 'true' ] &&
    [ "$runtime_dep_count" -ge 2 ] ||
    die 'The generated source runtime manifest is invalid.'

_staged_runtime_manifest_hash=$(sha256_of "$runtime_manifest")
_staged_runtime_manifest_bytes=$(bytes_of "$runtime_manifest")
[ "$_staged_runtime_manifest_hash" != "$MARKER_SHA256" ] &&
    [ "$_staged_runtime_manifest_bytes" -gt "$MARKER_BYTES" ] ||
    die 'The generated source runtime was not allowed to retain the source-only server marker.'

summary_client_compat="$PACKAGE_STAGE/app/summary-client-compat.js"
summary_client_bundle="$STAGED_SERVER/node_modules/@deepseek-ai/dsh-client-ui-deliverables/lib/client.js"
require_file "$summary_client_compat" 'The package summary client compatibility adapter is missing.'
require_file "$summary_client_bundle" 'The generated source runtime is missing the ui-deliverables client bundle.'
if ! node "$SUMMARY_CLIENT_CHECKER" "$summary_client_compat" "$summary_client_bundle"; then
    die 'The generated ui-deliverables client bundle is not the reviewed summary compatibility shape.'
fi

[ -f "$STAGED_SERVER/node_modules/yaml/package.json" ] ||
    die 'The generated source runtime is missing the YAML document parser required by DSH.'
[ "$(json_field "$STAGED_SERVER/node_modules/yaml/package.json" 'data["name"]')" = 'yaml' ] ||
    die 'The generated source runtime is missing the YAML document parser required by DSH.'

node_pty_path="$STAGED_SERVER/node_modules/node-pty/prebuilds/linux-x64/pty.node"
sharp_package_lib="$STAGED_SERVER/node_modules/@img/sharp-linux-x64/lib"
_landlock_package_dir="$LOCK_LANDLOCK_PACKAGE_NAME"
staged_landlock_path="$STAGED_SERVER/node_modules/$_landlock_package_dir/$LOCK_LANDLOCK_BINARY_PATH"
staged_flock_path="$STAGED_SERVER/node_modules/$_landlock_package_dir/bin/glibc/system.node"

sharp_nodes=$(find "$sharp_package_lib" -maxdepth 1 -type f -name '*.node' 2>/dev/null)
sharp_node_count=$(printf '%s\n' "$sharp_nodes" | count_lines)
[ "$sharp_node_count" -eq 1 ] ||
    die "Expected exactly one sharp linux-x64 native addon in $sharp_package_lib, got $sharp_node_count"
sharp_path=$(printf '%s\n' "$sharp_nodes" | sed '/^$/d' | head -n 1)

elf_machine_check "$node_pty_path" "$LOCK_ELF_MACHINE"
elf_machine_check "$sharp_path" "$LOCK_ELF_MACHINE"
elf_machine_check "$staged_landlock_path" "$LOCK_ELF_MACHINE"
elf_machine_check "$staged_flock_path" "$LOCK_ELF_MACHINE"

[ "$(sha256_of "$staged_landlock_path")" = "$official_landlock_hash" ] ||
    die 'The staged landlock-run binary differs from the locked official binary.'
[ "$(sha256_of "$staged_flock_path")" = "$(sha256_of "$official_flock_path")" ] ||
    die 'The staged flock addon differs from the locked official binary.'

_unexpected_targets=$(find "$STAGED_SERVER" -type f \
    \( -iname '*.exe' -o -iname '*.cmd' -o -iname '*.dll' -o -iname '*.pdb' \) 2>/dev/null | count_lines)
[ "$_unexpected_targets" -eq 0 ] ||
    die "Target-incompatible runtime files remain: $_unexpected_targets"

node_pty_prebuild_root="$STAGED_SERVER/node_modules/node-pty/prebuilds"
_unexpected_node_pty_platforms=$(find "$node_pty_prebuild_root" -mindepth 1 -maxdepth 1 -type d ! -name 'linux-x64' 2>/dev/null)
[ -z "$_unexpected_node_pty_platforms" ] ||
    die "Unsupported node-pty prebuild platforms remain: $(printf '%s\n' "$_unexpected_node_pty_platforms" | join_comma)"

# --- packaged pnpm -----------------------------------------------------------
tar -xzf "$resolved_pnpm" -C "$PNPM_STAGE" || die 'Unable to extract the locked pnpm tarball.'
pnpm_package_root="$PNPM_STAGE/package"
[ -d "$pnpm_package_root" ] ||
    die 'The locked pnpm tarball does not contain a package directory.'
_pnpm_name=$(json_field "$pnpm_package_root/package.json" 'data["name"]')
pnpm_package_version=$(json_field "$pnpm_package_root/package.json" 'data["version"]')
[ "$_pnpm_name" = 'pnpm' ] && [ "$pnpm_package_version" = "$LOCK_PNPM_VERSION" ] ||
    die "Unexpected pnpm package identity $_pnpm_name@$pnpm_package_version"

find "$pnpm_package_root" -type f \
    \( -iname '*.exe' -o -iname '*.cmd' -o -iname '*.dll' -o -iname '*.pdb' \) -delete 2>/dev/null
find "$pnpm_package_root" -type f \
    \( -name 'reflink.darwin-*.node' -o -name 'reflink.win32-*.node' \) -delete 2>/dev/null
for required_pnpm_file in LICENSE bin/pnpm.cjs bin/pnpm.mjs dist/pnpm.mjs; do
    [ -f "$pnpm_package_root/$required_pnpm_file" ] ||
        die "pnpm package is missing required file: $required_pnpm_file"
done
cp -R -- "$pnpm_package_root" "$PACKAGE_STAGE/app/pnpm" ||
    die 'Unable to stage the locked pnpm package.'

# --- build provenance --------------------------------------------------------
STAGED_APP_ROOT="$PACKAGE_STAGE/app"
printf '%s\n' "$BUILD_COMPONENT_PATHS" > "$STAGE/component-paths.txt"
: > "$STAGE/components-input.txt"
while IFS= read -r _component_rel; do
    [ -n "$_component_rel" ] || continue
    build_component "$STAGED_APP_ROOT" "$_component_rel" >> "$STAGE/components-input.txt"
done < "$STAGE/component-paths.txt"
component_count=$(count_lines < "$STAGE/components-input.txt")
[ "$component_count" -eq 22 ] ||
    die "Build provenance must record 22 components, got $component_count."

_python_build_info=$(python3 - "$STAGED_APP_ROOT/build-info.json" "$app_name" "$version" \
    "$LOCK_DSH_VERSION" "$LOCK_UPSTREAM_REPOSITORY" "$RESOLVED_COMMIT" "$RESOLVED_TREE" \
    "$MARKER_PATH_REL" "$MARKER_BYTES" "$MARKER_SHA256" "$STAGE/components-input.txt" 2>&1 <<'PY'
import json, sys

(output_path, app_name, version, dsh_version, repository, commit, tree,
 marker_path, marker_bytes, marker_sha256, components_path) = sys.argv[1:12]

components = []
with open(components_path, encoding="utf-8") as handle:
    for line in handle:
        line = line.rstrip("\n")
        if not line:
            continue
        path, byte_count, sha256 = line.split("|")
        components.append({"path": path, "bytes": int(byte_count), "sha256": sha256})

build_info = {
    "schema": 1,
    "app": {"name": app_name, "version": version},
    "upstream": {
        "package": "@deepseek-ai/dsh",
        "version": dsh_version,
        "repository": repository,
        "commit": commit,
        "tree": tree,
    },
    "build_input": {
        "server_marker": {
            "path": marker_path,
            "bytes": int(marker_bytes),
            "sha256": marker_sha256,
        },
    },
    "components": components,
}

# Same shape as ConvertTo-Json -Depth 8 in the PowerShell original: two space
# indentation, LF line endings, no BOM and a trailing newline.
with open(output_path, "w", encoding="utf-8") as handle:
    json.dump(build_info, handle, indent=2, ensure_ascii=False)
    handle.write("\n")
PY
) || die "$_python_build_info"
STAGED_BUILD_INFO_HASH=$(sha256_of "$STAGED_APP_ROOT/build-info.json")

# --- package -----------------------------------------------------------------
fnpack_path=$(bash "$FNPACK_RESOLVER" --platform linux --arch x64 --bundled-only) ||
    die 'Unable to resolve the bundled fnpack binary.'
printf 'fnpack=%s\n' "$fnpack_path"

# package-linux.sh <package-source> <runtime.tgz> <fnpack> <output-dir>
sh "$PACKAGE_SCRIPT" "$PACKAGE_STAGE" "$SOURCE_RUNTIME_ARCHIVE" "$fnpack_path" "$ARTIFACT_STAGE" ||
    die 'Linux fnpack failed.'

generated_artifacts=$(find "$ARTIFACT_STAGE" -maxdepth 1 -type f -name '*.fpk' | sort)
generated_count=$(printf '%s\n' "$generated_artifacts" | count_lines)
[ "$generated_count" -eq 1 ] ||
    die "fnpack must produce exactly $app_name.fpk in the isolated output directory; got: $(printf '%s\n' "$generated_artifacts" | join_comma)"
candidate_path=$(printf '%s\n' "$generated_artifacts" | sed '/^$/d' | head -n 1)
[ "$(basename -- "$candidate_path")" = "$app_name.fpk" ] ||
    die "fnpack must produce exactly $app_name.fpk in the isolated output directory."

# --- artifact verification ---------------------------------------------------
tar -tf "$candidate_path" > "$STAGE/outer-entries.raw" || die 'Unable to list the final FPK.'
sed 's|^\./||' "$STAGE/outer-entries.raw" > "$STAGE/outer-entries.txt"
for required_outer_entry in app.tgz cmd config manifest ICON.PNG ICON_256.PNG; do
    require_tar_entry "$STAGE/outer-entries.txt" "$required_outer_entry" 'Final FPK is missing required outer entry'
done
if grep -qxF 'LICENSE' "$STAGE/outer-entries.txt"; then
    die 'The final FPK unexpectedly contains an application-root LICENSE.'
fi

tar -xf "$candidate_path" -C "$VERIFY_STAGE" || die 'Unable to extract the final FPK.'
final_manifest="$VERIFY_STAGE/manifest"
[ -f "$final_manifest" ] || die 'The final FPK does not contain a readable manifest.'

_staged_manifest_fields="$STAGE/manifest-staged.txt"
_final_manifest_fields="$STAGE/manifest-final.txt"
manifest_field_pairs "$PACKAGE_STAGE/manifest" > "$_staged_manifest_fields" ||
    die 'Unable to read the staged manifest fields.'
manifest_field_pairs "$final_manifest" > "$_final_manifest_fields" ||
    die 'Unable to read the final manifest fields.'
_staged_manifest_duplicates=$(cut -d= -f1 "$_staged_manifest_fields" | sort | uniq -d)
[ -z "$_staged_manifest_duplicates" ] ||
    die "Manifest contains duplicate field ${_staged_manifest_duplicates}: $PACKAGE_STAGE/manifest"
_final_manifest_duplicates=$(cut -d= -f1 "$_final_manifest_fields" | sort | uniq -d)
[ -z "$_final_manifest_duplicates" ] ||
    die "Manifest contains duplicate field ${_final_manifest_duplicates}: $final_manifest"

while IFS= read -r _manifest_line; do
    [ -n "$_manifest_line" ] || continue
    grep -qxF -- "$_manifest_line" "$_final_manifest_fields" ||
        die "Final FPK manifest changed source field: ${_manifest_line%%=*}"
done < "$_staged_manifest_fields"

cut -d= -f1 "$_final_manifest_fields" | sort > "$STAGE/final-manifest-keys.txt"
cut -d= -f1 "$_staged_manifest_fields" | sort > "$STAGE/staged-manifest-keys.txt"
_generated_manifest_fields=$(grep -vxF -f "$STAGE/staged-manifest-keys.txt" "$STAGE/final-manifest-keys.txt")
_generated_field_count=$(printf '%s\n' "$_generated_manifest_fields" | count_lines)
[ "$_generated_field_count" -eq 1 ] && [ "$_generated_manifest_fields" = 'checksum' ] ||
    die "Final FPK manifest contains unexpected generated fields: $(printf '%s\n' "$_generated_manifest_fields" | join_comma)"
_generated_checksum=$(grep '^checksum=' "$_final_manifest_fields" | head -n 1)
_generated_checksum=${_generated_checksum#checksum=}
case "$_generated_checksum" in
    *[!0-9a-f]*|'') die 'Final FPK manifest checksum is not a 32 character MD5 value.' ;;
esac
[ "${#_generated_checksum}" -eq 32 ] ||
    die 'Final FPK manifest checksum is not a 32 character MD5 value.'

final_app_tgz="$VERIFY_STAGE/app.tgz"
[ -f "$final_app_tgz" ] || die 'The final FPK does not contain app.tgz.'
tar -tzf "$final_app_tgz" > "$STAGE/nested-entries.raw" || die 'Unable to list the final nested app.tgz.'
sed 's|^\./||' "$STAGE/nested-entries.raw" > "$STAGE/nested-entries.txt"
nested_file_count=$(count_lines < "$STAGE/nested-entries.txt")
tar -tvzf "$final_app_tgz" > "$STAGE/nested-modes.raw" ||
    die 'Unable to inspect final app.tgz entry modes.'
tar_mode_table < "$STAGE/nested-modes.raw" > "$STAGE/nested-modes.txt"
awk -F'\t' '$1 ~ /^-/ { print $2 }' "$STAGE/nested-modes.txt" | sort > "$STAGE/nested-files.txt"

if grep -qxF 'LICENSE' "$STAGE/nested-entries.txt"; then
    die 'The final app.tgz unexpectedly contains an application-root LICENSE.'
fi

printf '%s\n' "$REQUIRED_NESTED_ENTRIES" > "$STAGE/required-nested.txt"
while IFS= read -r _required_entry; do
    [ -n "$_required_entry" ] || continue
    require_tar_entry "$STAGE/nested-entries.txt" "$_required_entry" 'Final app.tgz is missing required entry'
done < "$STAGE/required-nested.txt"
while IFS='|' read -r _patch_rel _patch_artifact _patch_sha256 _patch_test_target; do
    [ -n "$_patch_artifact" ] || continue
    require_tar_entry "$STAGE/nested-entries.txt" "$_patch_artifact" 'Final app.tgz is missing required entry'
done < "$PATCH_LIST"

if grep -iqE '\.(exe|cmd|dll|pdb)$' "$STAGE/nested-files.txt"; then
    _incompatible_entries=$(grep -icE '\.(exe|cmd|dll|pdb)$' "$STAGE/nested-files.txt")
    die "Final app.tgz contains target-incompatible files: $_incompatible_entries"
fi

# node-pty prebuilds are only allowed for this target.
grep -E '^server/node_modules/node-pty/prebuilds/' "$STAGE/nested-files.txt" 2>/dev/null |
    grep -vE '^server/node_modules/node-pty/prebuilds/linux-x64/' > "$STAGE/node-pty-unsupported.txt" || :
if [ -s "$STAGE/node-pty-unsupported.txt" ]; then
    die "Final app.tgz contains unsupported node-pty prebuilds: $(count_lines < "$STAGE/node-pty-unsupported.txt")"
fi

# Prunable production runtime entries: source maps, TypeScript sources, test and
# documentation directories, C/C++ build inputs and package metadata noise. Each
# candidate must also live under server/node_modules, exactly as in the original.
grep -E '(^|/)server/node_modules/' "$STAGE/nested-files.txt" > "$STAGE/runtime-modules.txt" || :
: > "$STAGE/prunable.txt"
grep -iE '\.(map|cts|mts|ts)$' "$STAGE/nested-files.txt" > "$STAGE/prunable-a.txt" || :
grep -iE '(^|/)(\.circleci|\.github|\.nyc_output|\.yarn|__tests__|benchmarks?|coverage|docs?|examples?|tests?)(/|$)' \
    "$STAGE/nested-files.txt" |
    grep -ivE '^server/node_modules/yaml/(browser/)?dist/doc(/|$)' > "$STAGE/prunable-b.txt" || :
grep -iE '(^|/)(authors|changelog|changes|code_of_conduct|contributing|history|readme|security)(\.(markdown|md|rst|txt))?$' \
    "$STAGE/nested-files.txt" > "$STAGE/prunable-c.txt" || :
grep -iE '\.(asm|c|cc|cpp|gyp|gypi|h|hh|hpp|mk|s)$' "$STAGE/nested-files.txt" > "$STAGE/prunable-d.txt" || :
for _prunable_shard in "$STAGE/prunable-a.txt" "$STAGE/prunable-b.txt" "$STAGE/prunable-c.txt" "$STAGE/prunable-d.txt"; do
    [ -s "$_prunable_shard" ] || continue
    grep -xF -f "$_prunable_shard" "$STAGE/runtime-modules.txt" >> "$STAGE/prunable.txt" || :
done
sort -u -o "$STAGE/prunable.txt" "$STAGE/prunable.txt"
_prunable_count=$(count_lines < "$STAGE/prunable.txt")
[ "$_prunable_count" -eq 0 ] ||
    die "Final app.tgz contains prunable production runtime entries: $_prunable_count: $(head -n 20 "$STAGE/prunable.txt" | join_comma)"

final_landlock_entry='server/node_modules/@deepseek-ai/node-addon-system-linux-x64/bin/landlock-run'
_landlock_mode_rows=$(awk -F'\t' -v target="$final_landlock_entry" '$2 == target { print $1 }' "$STAGE/nested-modes.txt")
_landlock_mode_count=$(printf '%s\n' "$_landlock_mode_rows" | count_lines)
[ "$_landlock_mode_count" -eq 1 ] ||
    die 'The final app.tgz does not contain one inspectable landlock-run entry.'
landlock_archive_mode='restored-by-install-and-upgrade'
_landlock_mode_value=$(printf '%s\n' "$_landlock_mode_rows" | sed '/^$/d' | head -n 1)
case "$_landlock_mode_value" in
    -??x*) landlock_archive_mode='executable' ;;
esac
if [ "$landlock_archive_mode" != 'executable' ]; then
    grep -q 'prepare_landlock_launcher' "$PACKAGE_STAGE/cmd/install_callback" ||
        die 'The final app.tgz strips the landlock-run mode but lifecycle permission repair is missing.'
    grep -q 'prepare_landlock_launcher' "$PACKAGE_STAGE/cmd/upgrade_callback" ||
        die 'The final app.tgz strips the landlock-run mode but lifecycle permission repair is missing.'
fi

tar -xzf "$final_app_tgz" -C "$VERIFY_APP_STAGE" || die 'Unable to extract the final app.tgz.'
final_build_info="$VERIFY_APP_STAGE/build-info.json"
[ -f "$final_build_info" ] || die 'The final app.tgz does not contain build-info.json.'
final_build_info_hash=$(sha256_of "$final_build_info")
[ "$final_build_info_hash" = "$STAGED_BUILD_INFO_HASH" ] ||
    die 'The final app.tgz build-info.json differs from the staged build provenance.'

_payload_summary=$(python3 - "$final_build_info" "$VERIFY_APP_STAGE" "$STAGE/component-paths.txt" \
    "$app_name" "$version" "$LOCK_DSH_VERSION" "$LOCK_UPSTREAM_REPOSITORY" "$RESOLVED_COMMIT" \
    "$RESOLVED_TREE" "$MARKER_PATH_REL" "$MARKER_BYTES" "$MARKER_SHA256" 2>&1 <<'PY'
import hashlib, json, os, sys

(build_info_path, verify_root, component_paths_path, app_name, version, dsh_version,
 repository, commit, tree, marker_path, marker_bytes, marker_sha256) = sys.argv[1:13]

with open(build_info_path, encoding="utf-8") as handle:
    info = json.load(handle)

expected_paths = []
with open(component_paths_path, encoding="utf-8") as handle:
    for line in handle:
        line = line.rstrip("\n")
        if line:
            expected_paths.append(line)

if info.get("schema") != 1:
    raise SystemExit("The final app.tgz build provenance schema is invalid.")

app = info.get("app") or {}
upstream = info.get("upstream") or {}
if app.get("name") != app_name or app.get("version") != version:
    raise SystemExit("The final app.tgz build provenance identity is invalid.")
if (upstream.get("package") != "@deepseek-ai/dsh"
        or upstream.get("version") != dsh_version
        or upstream.get("repository") != repository
        or upstream.get("commit") != commit
        or upstream.get("tree") != tree):
    raise SystemExit("The final app.tgz build provenance identity is invalid.")

marker = (info.get("build_input") or {}).get("server_marker") or {}
if (marker.get("path") != marker_path
        or str(marker.get("bytes")) != str(marker_bytes)
        or marker.get("sha256") != marker_sha256):
    raise SystemExit("The final app.tgz does not identify the source-only server marker correctly.")

components = info.get("components")
if not isinstance(components, list) or len(components) != len(expected_paths):
    raise SystemExit("The final app.tgz build provenance component count is invalid.")

for index, expected_path in enumerate(expected_paths):
    recorded = components[index] or {}
    if recorded.get("path") != expected_path:
        raise SystemExit("The final app.tgz build provenance component order is invalid at index %d." % index)
    native = os.path.join(verify_root, expected_path)
    if not os.path.isfile(native):
        raise SystemExit("The final app.tgz build provenance component is missing: " + expected_path)
    digest = hashlib.sha256()
    byte_count = 0
    with open(native, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
            byte_count += len(chunk)
    if str(recorded.get("bytes")) != str(byte_count) or recorded.get("sha256") != digest.hexdigest():
        raise SystemExit("The final app.tgz component differs from build provenance: " + expected_path)

file_count = 0
total_bytes = 0
for root, _directories, files in os.walk(verify_root):
    for name in files:
        file_count += 1
        total_bytes += os.lstat(os.path.join(root, name)).st_size

print("%d\t%d" % (file_count, total_bytes))
PY
) || die "$_payload_summary"
payload_file_count=$(printf '%s\n' "$_payload_summary" | head -n 1 | cut -f1)
payload_logical_bytes=$(printf '%s\n' "$_payload_summary" | head -n 1 | cut -f2)

while IFS='|' read -r _patch_rel _patch_artifact _patch_sha256 _patch_test_target; do
    [ -n "$_patch_artifact" ] || continue
    final_patch_path="$VERIFY_APP_STAGE/$_patch_artifact"
    [ -f "$final_patch_path" ] ||
        die "The final app.tgz is missing the locked source patch: $_patch_artifact"
    [ "$(sha256_of "$final_patch_path")" = "$_patch_sha256" ] ||
        die "The final app.tgz source patch differs from the locked build input: $_patch_artifact"
done < "$PATCH_LIST"

final_landlock_path="$VERIFY_APP_STAGE/$final_landlock_entry"
elf_machine_check "$final_landlock_path" "$LOCK_ELF_MACHINE"
final_landlock_hash=$(sha256_of "$final_landlock_path")
[ "$final_landlock_hash" = "$official_landlock_hash" ] ||
    die 'The final app.tgz landlock-run binary differs from the locked official binary.'

candidate_bytes=$(bytes_of "$candidate_path")
candidate_hash=$(sha256_of "$candidate_path")
mv -- "$candidate_path" "$TARGET_PATH" ||
    die "Unable to move the verified artifact into $TARGET_PATH"
artifact_bytes=$(bytes_of "$TARGET_PATH")
artifact_hash=$(sha256_of "$TARGET_PATH")
[ "$artifact_bytes" = "$candidate_bytes" ] && [ "$artifact_hash" = "$candidate_hash" ] ||
    die 'The versioned FPK changed while it was moved from the isolated staging directory.'
FINALIZED=1

# --- report ------------------------------------------------------------------
printf 'AppName=%s\n' "$app_name"
printf 'Version=%s\n' "$version"
printf 'Artifact=%s\n' "$TARGET_PATH"
printf 'Bytes=%s\n' "$artifact_bytes"
printf 'SHA256=%s\n' "$artifact_hash"
printf 'SourceRepository=%s\n' "$LOCK_UPSTREAM_REPOSITORY"
printf 'SourceCommit=%s\n' "$RESOLVED_COMMIT"
printf 'SourceTree=%s\n' "$RESOLVED_TREE"
while IFS='|' read -r _patch_rel _patch_artifact _patch_sha256 _patch_test_target; do
    [ -n "$_patch_artifact" ] || continue
    printf 'SourcePatch=%s sha256=%s test=%s\n' "$_patch_artifact" "$_patch_sha256" "$_patch_test_target"
done < "$PATCH_LIST"
printf 'RuntimeVersion=%s\n' "$dsh_package_version"
printf 'RuntimeWorkspacePackages=%s\n' "$runtime_dep_count"
printf 'PnpmVersion=%s\n' "$pnpm_package_version"
printf 'PnpmSHA256=%s\n' "$LOCK_PNPM_ASSET_SHA256"
printf 'LandlockVersion=%s\n' "$LOCK_LANDLOCK_VERSION"
printf 'LandlockSHA256=%s\n' "$LOCK_LANDLOCK_ASSET_SHA256"
printf 'LandlockBinarySHA256=%s\n' "$final_landlock_hash"
printf 'LandlockArchiveMode=%s\n' "$landlock_archive_mode"
printf 'BuildInfoSHA256=%s\n' "$final_build_info_hash"
printf 'BuildComponents=%s\n' "$component_count"
printf 'Platform=%s\n' "$LOCK_TARGET"
printf 'NativeMachine=%s\n' "$LOCK_ELF_MACHINE"
printf 'NestedFiles=%s\n' "$nested_file_count"
printf 'NestedRegularFiles=%s\n' "$payload_file_count"
printf 'NestedLogicalBytes=%s\n' "$payload_logical_bytes"
printf 'Result=passed\n'
