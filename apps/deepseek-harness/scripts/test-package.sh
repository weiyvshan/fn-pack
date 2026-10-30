#!/bin/sh
# Source contract test for the deepseek-harness fnOS package.
#
# Native fnOS/Debian validation of the FPK source tree: JSON contracts, POSIX
# shell syntax, line endings, icon dimensions, bundled skill inventory and
# hashes, lifecycle/launcher/gateway source contracts, locked upstream source
# patches, the vendored fnOS JS SDK, and behaviour suites implemented in Node.js
# or POSIX shell.
#
# Checks that need the surrounding packaging repository (a git work tree
#     with the locked vendor/upstream submodule) are reported as skipped when
#     that tree is absent, so the package stays testable from
#     apps/deepseek-harness alone. See the trailing report for their state.
set -u

PROJECT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# The packaging repository root carries vendor/upstream, .gitmodules and the
# skill that owns the static audit; it sits two levels above the package tree.
REPO_ROOT=''
for candidate in "$PROJECT/../.." "$PROJECT/.."; do
    resolved=$(CDPATH= cd -- "$candidate" 2>/dev/null && pwd) || continue
    if [ -d "$resolved/vendor/upstream" ] || [ -d "$resolved/.agents/skills/fnnas-app-creator" ]; then
        REPO_ROOT="$resolved"
        break
    fi
done
[ -n "$REPO_ROOT" ] || REPO_ROOT=$(CDPATH= cd -- "$PROJECT/../.." 2>/dev/null && pwd || printf '%s' "$PROJECT")

SKILL_ROOT="$REPO_ROOT/.agents/skills/fnnas-app-creator"
AUDIT_SCRIPT="$SKILL_ROOT/scripts/audit_fnos_project.sh"
GITMODULES="$REPO_ROOT/.gitmodules"
TERMINAL_BASH_TS="$REPO_ROOT/.tmp/deepseek-harness-upstream/packages/terminal/terminal-bash/src/index.ts"
BUNDLED_SKILL_CREATOR_ROOT="$PROJECT/app/builtin-skills/skill-creator"
SOURCE_CHECKOUT_SUITE="$PROJECT/tests/source-checkout.test.sh"

# Reviewed SHA-256 contract for the bundled skill-creator fnOS/Linux subset.
# The package includes no executable PowerShell scripts.
BUNDLED_SKILL_CREATOR_PATHS='SKILL.md
references/openai_yaml.md
references/powershell-authoring.md
scripts/generate_openai_yaml.sh
scripts/init_skill.sh
scripts/quick_validate.sh'
BUNDLED_SKILL_CREATOR_HASHES='d34217ee6a048c57e5dda79374ce92c55e798bead5fce65db5873ad9fb4039ef
9fb5928b7f4a746fdb39df503ebbd7a659d5e64b47f85a60626aa1a03fd76b17
68f4ea1d189fd7d9942dfdadb75e629405ce454f68577477458545e2637bbc4c
370cb18721efc9f7c6127aaebd2a367ec2118970c2dc4f8d4ff801e89324aecb
b60b85b9ac693215ecd1d4578f350b014f9fd8b9a9ae91789771f47725114edb
2f070718580206c62b5e547a5e7cd700b4eb2211aac8527e147311cf374bd7d8'

JSON_TOOL=''
BASH_BIN=''
NODE_BIN=''
CR=$(printf '\r')

# Reported states for the checks that depend on the surrounding repository.
GIT_LOCK_STATE='pending'
VENDOR_STATE='pending'
RESOLVER_STATE='pending'
AUDIT_STATE='pending'

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

note_skip() {
    printf 'SKIP: %s\n' "$*" >&2
}

# --- tool discovery ----------------------------------------------------------
# JSON contracts are validated with python3; the checks are reported as skipped
# when the host carries no interpreter instead of being silently accepted.
if command -v python3 >/dev/null 2>&1; then
    JSON_TOOL=python3
fi
if command -v bash >/dev/null 2>&1; then
    BASH_BIN=bash
fi
[ -n "$BASH_BIN" ] || fail 'bash was not found on PATH; the bundled skill-creator validator and the POSIX suites require it.'
NODE_BIN=$(command -v node 2>/dev/null || true)
[ -n "$NODE_BIN" ] || fail 'node was not found on PATH; the JavaScript contract tests are required.'

json_get() {
    # json_get <file> <python-expression-on-data>
    _file=$1
    _expr=$2
    case "$JSON_TOOL" in
        python3)
            python3 -c '
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
value = eval(sys.argv[2], {"__builtins__": {"len": len, "str": str, "int": int, "next": next}}, {"data": data})
if isinstance(value, bool):
    print("true" if value else "false")
elif value is None:
    print("")
else:
    print(value)
' "$_file" "$_expr"
            ;;
        *)
            printf 'SKIP\n'
            ;;
    esac
}

json_valid() {
    case "$JSON_TOOL" in
        python3) python3 -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$1" >/dev/null 2>&1 ;;
        *) return 0 ;;
    esac
}

# --- assertion helpers -------------------------------------------------------
assert_eq() {
    [ "$1" = "$2" ] || fail "$3 (got [$1], want [$2])"
}

assert_ere() {
    # assert_ere <value> <extended-regex> <message>
    printf '%s\n' "$1" | LC_ALL=C grep -qE -- "$2" || fail "$3 (got [$1])"
}

require_file() {
    [ -f "$1" ] || fail "$2 (missing file: $1)"
}

contains() {
    # contains <file> <literal> <message>
    _file=$1
    _literal=$2
    _message=$3
    [ -f "$_file" ] || fail "$_message (missing file: $_file)"
    LC_ALL=C grep -qF -- "$_literal" "$_file" || fail "$_message (missing [$_literal] in $_file)"
}

not_contains() {
    _file=$1
    _literal=$2
    _message=$3
    [ -f "$_file" ] || fail "$_message (missing file: $_file)"
    if LC_ALL=C grep -qF -- "$_literal" "$_file"; then
        fail "$_message (unexpected [$_literal] in $_file)"
    fi
}

matches() {
    # matches <file> <extended-regex> <message>
    _file=$1
    _ere=$2
    _message=$3
    [ -f "$_file" ] || fail "$_message (missing file: $_file)"
    LC_ALL=C grep -qE -- "$_ere" "$_file" || fail "$_message (pattern [$_ere] not found in $_file)"
}

not_matches() {
    _file=$1
    _ere=$2
    _message=$3
    [ -f "$_file" ] || fail "$_message (missing file: $_file)"
    if LC_ALL=C grep -qE -- "$_ere" "$_file"; then
        fail "$_message (pattern [$_ere] matched in $_file)"
    fi
}

none_matches() {
    # none_matches <extended-regex> <message> <file>... : every file must be free
    # of the pattern.
    _ere=$1
    _message=$2
    shift 2
    for _file in "$@"; do
        if LC_ALL=C grep -qE -- "$_ere" "$_file"; then
            fail "$_message (pattern [$_ere] matched in $_file)"
        fi
    done
}

seq_match() {
    # seq_match <file> <token>... : tokens must occur in order, each after the
    # previous one and possibly on later lines.
    _file=$1
    shift
    LC_ALL=C awk -v n="$#" \
        -v t1="${1:-}" -v t2="${2:-}" -v t3="${3:-}" -v t4="${4:-}" \
        -v t5="${5:-}" -v t6="${6:-}" -v t7="${7:-}" -v t8="${8:-}" '
        BEGIN {
            want[1] = t1; want[2] = t2; want[3] = t3; want[4] = t4
            want[5] = t5; want[6] = t6; want[7] = t7; want[8] = t8
            index_needed = 1
        }
        {
            rest = $0
            while (index_needed <= n) {
                position = index(rest, want[index_needed])
                if (position == 0) { break }
                rest = substr(rest, position + length(want[index_needed]))
                index_needed = index_needed + 1
            }
        }
        END { if (index_needed > n) { exit 0 } else { exit 1 } }
    ' "$_file"
}

sha256_of() {
    sha256sum "$1" | awk '{print $1}'
}

file_bytes() {
    stat -c '%s' "$1"
}

count_matches() {
    # count_matches <file> <literal>: number of literal occurrences on all lines.
    grep -o -F -- "$2" "$1" 2>/dev/null | wc -l | tr -d ' '
}

manifest_value() {
    # manifest_value <key>: first "key = value" line wins, matching fnOS parsing.
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$PROJECT/manifest" | head -n 1 | sed 's/[[:space:]]*$//'
}

png_dimensions() {
    # Prints "<width>x<height>" read from the PNG IHDR chunk.
    od -An -tu1 -j16 -N8 "$1" 2>/dev/null | awk '
        {
            count = NF
            for (n = 1; n <= NF; n++) values[n] = $n
        }
        END {
            if (count < 8) { print "unknown"; exit }
            width = values[1] * 16777216 + values[2] * 65536 + values[3] * 256 + values[4]
            height = values[5] * 16777216 + values[6] * 65536 + values[7] * 256 + values[8]
            printf "%dx%d\n", width, height
        }'
}

list_shell_files() {
    # Mirrors $shellFiles: cmd/* plus every packaged POSIX shell script.
    find "$PROJECT/cmd" -type f
    printf '%s\n' \
        "$PROJECT/app/dsh-launcher" \
        "$PROJECT/app/pnpm-launcher" \
        "$PROJECT/scripts/build-fpk.sh" \
        "$PROJECT/scripts/build-source-runtime.sh" \
        "$PROJECT/scripts/package-linux.sh" \
        "$PROJECT/scripts/materialize-workspace-links.sh" \
        "$PROJECT/scripts/resolve-upstream-source.sh" \
        "$PROJECT/scripts/check-line-endings.sh" \
        "$PROJECT/scripts/test-package.sh" \
        "$PROJECT/tests/source-checkout.test.sh" \
        "$PROJECT/tests/build-artifact-guard.test.sh" \
        "$PROJECT/tests/pnpm-launcher.test.sh" \
        "$PROJECT/tests/dsh-launcher.test.sh" \
        "$PROJECT/tests/main-lifecycle.test.sh" \
        "$PROJECT/tests/process-group.test.sh" \
        "$PROJECT/tests/log-resilience.test.sh" \
        "$PROJECT/tests/auth-token.test.sh" \
        "$PROJECT/tests/skill-creator.test.sh" \
        "$BUNDLED_SKILL_CREATOR_ROOT/scripts/generate_openai_yaml.sh" \
        "$BUNDLED_SKILL_CREATOR_ROOT/scripts/init_skill.sh" \
        "$BUNDLED_SKILL_CREATOR_ROOT/scripts/quick_validate.sh"
}

list_text_files() {
    # Mirrors $textFiles: every file that must stay LF-only in the fpk source.
    printf '%s\n' $SHELL_FILES
    printf '%s\n' \
        "$BUNDLED_SKILL_CREATOR_ROOT/SKILL.md" \
        "$BUNDLED_SKILL_CREATOR_ROOT/references/openai_yaml.md" \
        "$BUNDLED_SKILL_CREATOR_ROOT/references/powershell-authoring.md" \
        "$BUNDLED_SKILL_CREATOR_ROOT/scripts/generate_openai_yaml.sh" \
        "$BUNDLED_SKILL_CREATOR_ROOT/scripts/init_skill.sh" \
        "$BUNDLED_SKILL_CREATOR_ROOT/scripts/quick_validate.sh" \
        "$PROJECT/app/builtin-skills/dsh-maintenance/SKILL.md" \
        "$PROJECT/app/gateway-proxy.js" \
        "$PROJECT/app/gateway-compat.js" \
        "$PROJECT/app/gateway-websocket.js" \
        "$PROJECT/app/summary-client-compat.js" \
        "$PROJECT/app/select-loopback-port.js" \
        "$PROJECT/app/backend-ready.js" \
        "$PROJECT/app/web/fnos-open-enhancer.js" \
        "$PROJECT/scripts/check-summary-client.mjs" \
        "$PROJECT/scripts/generate-source-runtime.mjs" \
        "$PROJECT/scripts/prune-source-runtime.mjs" \
        "$PROJECT/scripts/check-line-endings.sh" \
        "$PROJECT/scripts/check-line-endings.ps1" \
        "$PROJECT/patches/0002-dsh-plugin-profile-scoped-management.patch" \
        "$PROJECT/patches/0004-web-app-private-auth-token-handoff.patch" \
        "$PROJECT/patches/0007-attachment-storage-respect-access-boundary.patch" \
        "$PROJECT/patches/0008-fnos-transport-defaults.patch" \
        "$PROJECT/patches/0009-dsh-file-upload-agent-resolver-release.patch" \
        "$PROJECT/tests/config-common.test.sh" \
        "$PROJECT/tests/fnos-open-enhancer.test.js" \
        "$PROJECT/tests/gateway-websocket.test.js" \
        "$PROJECT/tests/summary-client-compat.test.js" \
        "$PROJECT/tests/gateway-transport.test.js" \
        "$PROJECT/tests/summary-client-build.test.js" \
        "$PROJECT/tests/fixtures/summary-client-bundle.js" \
        "$PROJECT/tests/generate-source-runtime.test.mjs" \
        "$PROJECT/tests/prune-source-runtime.test.mjs"
}

SHELL_FILES=$(list_shell_files | LC_ALL=C sort)
TEXT_FILES=$(list_text_files)

# --- JSON contracts ----------------------------------------------------------
JSON_FILES='config/privilege
config/resource
app/ui/config
wizard/install
wizard/config
app/server/package.json
runtime.lock.json'
json_file_count=0
for relative_path in $JSON_FILES; do
    json_file_count=$((json_file_count + 1))
    path="$PROJECT/$relative_path"
    require_file "$path" "Required JSON contract is missing: $relative_path"
    json_valid "$path" || fail "Not valid JSON: $relative_path"
done

# --- POSIX shell syntax ------------------------------------------------------
shell_syntax_count=0
for script in $SHELL_FILES; do
    require_file "$script" 'A packaged POSIX shell script is missing.'
    if [ -n "$BASH_BIN" ]; then
        "$BASH_BIN" -n "$script" || fail "Shell syntax validation failed: $script"
    else
        sh -n "$script" || fail "Shell syntax validation failed: $script"
    fi
    shell_syntax_count=$((shell_syntax_count + 1))
done

# --- LF-only line endings ----------------------------------------------------
# A carriage return directly in front of the line ending is a CRLF byte pair.
for text_file in $TEXT_FILES; do
    require_file "$text_file" 'A NAS runtime file is missing.'
    if LC_ALL=C grep -q "${CR}\$" "$text_file"; then
        fail "CRLF line endings are not allowed in NAS runtime files: $text_file"
    fi
done

# --- repository-wide line endings ---------------------------------------------
# The packaged files are only part of the repository: the bootstrap script, the
# release workflow and every other tracked text file must stay LF as well, or a
# Windows checkout breaks the Linux build and the patch application.
bash "$PROJECT/scripts/check-line-endings.sh" "$REPO_ROOT" ||
    fail 'The repository line-ending guard reported CRLF content.'

# --- bundled skill-creator validation ----------------------------------------
"$BASH_BIN" "$BUNDLED_SKILL_CREATOR_ROOT/scripts/quick_validate.sh" "$BUNDLED_SKILL_CREATOR_ROOT" ||
    fail 'Bundled skill-creator validation failed.'

# --- JavaScript syntax -------------------------------------------------------
for js_file in \
    "$PROJECT/app/gateway-proxy.js" \
    "$PROJECT/app/gateway-compat.js" \
    "$PROJECT/app/gateway-websocket.js" \
    "$PROJECT/app/summary-client-compat.js" \
    "$PROJECT/app/select-loopback-port.js" \
    "$PROJECT/app/backend-ready.js" \
    "$PROJECT/app/web/fnos-open-enhancer.js" \
    "$PROJECT/scripts/check-summary-client.mjs" \
    "$PROJECT/tests/summary-client-build.test.js" \
    "$PROJECT/tests/fixtures/summary-client-bundle.js" \
    "$PROJECT/scripts/generate-source-runtime.mjs" \
    "$PROJECT/scripts/prune-source-runtime.mjs"
do
    require_file "$js_file" 'A runtime JavaScript module is missing.'
    "$NODE_BIN" --check "$js_file" || fail "JavaScript syntax validation failed: $js_file"
done

# --- loopback port selector --------------------------------------------------
selected_port=$("$NODE_BIN" "$PROJECT/app/select-loopback-port.js" 2>/dev/null) ||
    fail 'Loopback port selection failed.'
case "$selected_port" in
    ''|*[!0-9]*) fail "Loopback port selector returned an invalid port: [$selected_port]" ;;
    *) : ;;
esac
if [ "$selected_port" -lt 1 ] || [ "$selected_port" -gt 65535 ]; then
    fail "Loopback port selector returned an invalid port: [$selected_port]"
fi

# --- behaviour suites --------------------------------------------------------
"$NODE_BIN" "$PROJECT/tests/gateway-proxy.test.js" || fail 'gateway-proxy tests failed.'
"$NODE_BIN" "$PROJECT/tests/gateway-websocket.test.js" || fail 'gateway-websocket tests failed.'
"$NODE_BIN" "$PROJECT/tests/gateway-transport.test.js" || fail 'gateway-transport tests failed.'
"$NODE_BIN" "$PROJECT/tests/summary-client-compat.test.js" || fail 'summary-client-compat tests failed.'
"$NODE_BIN" "$PROJECT/tests/summary-client-build.test.js" || fail 'summary-client build gate tests failed.'
"$NODE_BIN" "$PROJECT/tests/fnos-open-enhancer.test.js" || fail 'fnos-open-enhancer tests failed.'
"$NODE_BIN" "$PROJECT/tests/gateway-compat.test.js" || fail 'gateway-compat tests failed.'
"$NODE_BIN" "$PROJECT/tests/backend-ready.test.js" || fail 'backend-ready tests failed.'
"$BASH_BIN" "$PROJECT/tests/config-common.test.sh" || fail 'config-common tests failed.'
"$BASH_BIN" "$PROJECT/tests/pnpm-launcher.test.sh" || fail 'pnpm launcher tests failed.'
"$BASH_BIN" "$PROJECT/tests/dsh-launcher.test.sh" || fail 'dsh launcher tests failed.'
"$BASH_BIN" "$PROJECT/tests/main-lifecycle.test.sh" || fail 'main lifecycle tests failed.'
"$BASH_BIN" "$PROJECT/tests/process-group.test.sh" || fail 'process group tests failed.'
"$BASH_BIN" "$PROJECT/tests/log-resilience.test.sh" || fail 'log resilience tests failed.'
"$BASH_BIN" "$PROJECT/tests/auth-token.test.sh" || fail 'browser authentication token tests failed.'
"$BASH_BIN" "$PROJECT/tests/skill-creator.test.sh" || fail 'skill-creator tests failed.'
"$NODE_BIN" "$PROJECT/tests/generate-source-runtime.test.mjs" || fail 'generate-source-runtime tests failed.'
"$NODE_BIN" "$PROJECT/tests/prune-source-runtime.test.mjs" || fail 'prune-source-runtime tests failed.'

# The upstream resolver regression suite is native POSIX shell on Linux.
require_file "$SOURCE_CHECKOUT_SUITE" 'The native source checkout resolver test is missing.'
"$BASH_BIN" "$SOURCE_CHECKOUT_SUITE" || fail 'source checkout resolver tests failed.'
RESOLVER_STATE='passed'
"$BASH_BIN" "$PROJECT/tests/build-artifact-guard.test.sh" || fail 'build artifact guard tests failed.'

# --- icons -------------------------------------------------------------------
for spec in 'ICON.PNG=64' 'ICON_256.PNG=256' 'app/ui/images/icon_64.png=64' 'app/ui/images/icon_256.png=256'
do
    icon=${spec%%=*}
    size=${spec#*=}
    path="$PROJECT/$icon"
    [ -f "$path" ] || fail "Icon is missing: $icon"
    [ "$(file_bytes "$path")" -ge 24 ] || fail "Invalid PNG (shorter than the 24-byte header): $icon"
    assert_eq "$(png_dimensions "$path")" "${size}x${size}" "Unexpected icon dimensions for $icon."
done

# --- lifecycle, launcher and gateway source contracts ------------------------
MAIN="$PROJECT/cmd/main"
CONFIG_COMMON="$PROJECT/cmd/config-common"
INSTALL_CALLBACK="$PROJECT/cmd/install_callback"
UNINSTALL_CALLBACK="$PROJECT/cmd/uninstall_callback"
UPGRADE_INIT="$PROJECT/cmd/upgrade_init"
UPGRADE_CALLBACK="$PROJECT/cmd/upgrade_callback"
GATEWAY_PROXY="$PROJECT/app/gateway-proxy.js"
FNOS_OPEN_ENHANCER="$PROJECT/app/web/fnos-open-enhancer.js"
DSH_LAUNCHER="$PROJECT/app/dsh-launcher"
PNPM_LAUNCHER="$PROJECT/app/pnpm-launcher"
BUILD_FPK="$PROJECT/scripts/build-fpk.sh"
PACKAGE_LINUX="$PROJECT/scripts/package-linux.sh"
SOURCE_RESOLVER="$PROJECT/scripts/resolve-upstream-source.sh"
SOURCE_BUILD="$PROJECT/scripts/build-source-runtime.sh"
SOURCE_PRUNER="$PROJECT/scripts/prune-source-runtime.mjs"
MAINTENANCE_SKILL="$PROJECT/app/builtin-skills/dsh-maintenance/SKILL.md"
SKILL_CREATOR_SKILL="$BUNDLED_SKILL_CREATOR_ROOT/SKILL.md"

for required in "$MAIN" "$CONFIG_COMMON" "$INSTALL_CALLBACK" "$UNINSTALL_CALLBACK" "$UPGRADE_INIT" \
    "$UPGRADE_CALLBACK" "$GATEWAY_PROXY" "$FNOS_OPEN_ENHANCER" "$DSH_LAUNCHER" "$PNPM_LAUNCHER" \
    "$BUILD_FPK" "$PACKAGE_LINUX" "$SOURCE_RESOLVER" "$SOURCE_BUILD" "$SOURCE_PRUNER" \
    "$MAINTENANCE_SKILL" "$SKILL_CREATOR_SKILL"
do
    require_file "$required" 'A required package source file is missing.'
done

# The application root must not ship a LICENSE file.
[ ! -e "$PROJECT/LICENSE" ] || fail 'The application root must not contain a LICENSE file.'

# The manifest identity is frozen for this release.
assert_eq "$(manifest_value appname)" 'deepseek-harness' 'The DeepSeek Harness manifest must use appname deepseek-harness.'
assert_eq "$(manifest_value version)" '0.0.24' 'The DeepSeek Harness manifest must use version 0.0.24.'
assert_eq "$(manifest_value platform)" 'x86' 'The DeepSeek Harness manifest must use x86 platform naming.'

# The bundled dsh-maintenance skill must match the reviewed source.
assert_eq "$(sha256_of "$MAINTENANCE_SKILL")" \
    '309f2d6973a678533493905a779ea097a9be17c26d32aaa9bea2614e56ed07df' \
    'The bundled dsh-maintenance skill must match the reviewed source.'
matches "$MAINTENANCE_SKILL" '^name: dsh-maintenance$' \
    'The bundled dsh-maintenance skill must declare its identity.'
not_matches "$MAINTENANCE_SKILL" '^name: gateway-route-injection$' \
    'The bundled dsh-maintenance skill must not keep the retired identity.'

# The bundled init skill is a reviewed document-only snapshot.
INIT_SKILL_ROOT="$PROJECT/app/builtin-skills/init"
init_inventory=$(find "$INIT_SKILL_ROOT" -type f | sed "s|^$INIT_SKILL_ROOT/||" | LC_ALL=C sort)
assert_eq "$init_inventory" "$(printf 'SKILL.md\nagents/openai.yaml\n')" 'The bundled init inventory must contain exactly the reviewed documents.'
assert_eq "$(sha256_of "$INIT_SKILL_ROOT/SKILL.md")" '9f834c4620402e30b113d8998a6bf3521f3ae076bb1144eed5dddcfa464af057' 'The bundled init skill differs from the reviewed source.'
assert_eq "$(sha256_of "$INIT_SKILL_ROOT/agents/openai.yaml")" '8a3e6b0e48d55d37244937e3e1a17fdab82754a057d9182a67273a1844680e40' 'The bundled init interface differs from the reviewed source.'
matches "$INIT_SKILL_ROOT/SKILL.md" '^name: init$' 'The bundled init skill must declare its identity.'
for init_path in builtin-skills/init/SKILL.md builtin-skills/init/agents/openai.yaml; do
    [ "$(count_matches "$BUILD_FPK" "$init_path")" -ge 2 ] || fail "The FPK must record and require $init_path"
done

# The bundled skill-creator inventory must be exactly the reviewed subset.
skill_creator_actual=$(find "$BUNDLED_SKILL_CREATOR_ROOT" -type f |
    sed "s|^$BUNDLED_SKILL_CREATOR_ROOT/||" | LC_ALL=C sort)
skill_creator_expected=$(printf '%s\n' $BUNDLED_SKILL_CREATOR_PATHS | LC_ALL=C sort)
assert_eq "$skill_creator_actual" "$skill_creator_expected" \
    'The bundled skill-creator inventory must contain exactly the reviewed fnOS/Linux source subset and no PowerShell scripts.'

# Every bundled skill-creator file must match the reviewed hash contract.
skill_index=1
for relative_path in $BUNDLED_SKILL_CREATOR_PATHS; do
    expected_hash=$(printf '%s\n' $BUNDLED_SKILL_CREATOR_HASHES | sed -n "${skill_index}p")
    skill_file="$BUNDLED_SKILL_CREATOR_ROOT/$relative_path"
    require_file "$skill_file" "The bundled skill-creator file is missing: $relative_path"
    assert_eq "$(sha256_of "$skill_file")" "$expected_hash" \
        "The bundled skill-creator file differs from the reviewed source contract: $relative_path"
    skill_index=$((skill_index + 1))
done

matches "$SKILL_CREATOR_SKILL" '^name: skill-creator$' \
    'The bundled skill-creator identity is invalid.'
skill_creator_ps1=$(find "$BUNDLED_SKILL_CREATOR_ROOT" -type f -name '*.ps1' | wc -l | tr -d ' ')
assert_eq "$skill_creator_ps1" '0' \
    'A PowerShell script remains in the fnOS package source.'

# The retired bundled gateway-route-injection skill path must be gone.
[ ! -e "$PROJECT/app/builtin-skills/gateway-route-injection" ] ||
    fail 'The retired bundled gateway-route-injection skill path must not remain in the package source.'

# Gateway-only applications must not declare a fixed platform port.
not_matches "$PROJECT/manifest" '^[[:space:]]*(service_port|checkport)[[:space:]]*=' \
    'Gateway-only applications must not declare service_port or checkport.'

# Lifecycle script must use the loopback selector and the readiness contract.
not_contains "$MAIN" 'TRIM_SERVICE_PORT' \
    'Lifecycle script still contains the fixed-port contract.'
contains "$MAIN" 'select-loopback-port.js' \
    'Lifecycle script must use the loopback port selector.'
not_matches "$MAIN" '\b120\b' \
    'Lifecycle script still contains the long synchronous-start contract.'
matches "$MAIN" 'backend-ready\.js' 'Lifecycle script must probe backend readiness.'
matches "$MAIN" '45' 'Lifecycle startup must keep the bounded readiness wait.'
matches "$MAIN" '\$DSH_PID' 'Lifecycle startup must track the DSH process id.'
matches "$MAIN" 'STARTUP_STABILITY_SECONDS=15' 'Lifecycle startup must keep the stability window.'
matches "$MAIN" 'wait_for_backend_stability' 'Lifecycle startup must keep the stability wait.'

# Lifecycle, callbacks and upgrade hooks must not migrate profile, data or
# runtime state (the PowerShell original checks each file separately).
not_matches "$MAIN" \
    'apply_profile_compatibility|apply_profile_plugin_gate|start_service_with_upgrade_recovery|restore_pending_packaged_runtime|commit_packaged_runtime_upgrade' \
    'Lifecycle scripts must not perform profile, data, or runtime migration during startup.'
not_matches "$CONFIG_COMMON" \
    'migrate_dsh_home|migrate_profile_conflicts|upgrade-runtime-backup|stage_packaged_runtime_for_upgrade|restore_pending_packaged_runtime|commit_packaged_runtime_upgrade' \
    'Lifecycle scripts must not perform profile, data, or runtime migration during startup.'
not_matches "$UPGRADE_INIT" 'migrate|stage_|restore_|upgrade-runtime' \
    'Upgrade hooks must not perform profile, data, or runtime migration.'
not_matches "$UPGRADE_CALLBACK" 'migrate|stage_|restore_|upgrade-runtime' \
    'Upgrade hooks must not perform profile, data, or runtime migration.'

# Startup must reject an unexpected UID before persistent-state writes.
seq_match "$MAIN" 'require_package_start_identity()' 'id -u' 'TRIM_UID' '必须通过 fnOS 应用中心启用' ||
    fail 'Lifecycle startup must reject an unexpected UID before persistent-state writes.'
seq_match "$MAIN" 'start_service() {' 'require_package_start_identity || return 1' ||
    fail 'Lifecycle startup must reject an unexpected UID before persistent-state writes.'

# Startup must not persist a second DSH webserver port source.
not_matches "$MAIN" 'write_loopback_profile|cordis\.patch\.yml' \
    'Lifecycle startup must not persist a second DSH webserver port source.'

# The fnOS gateway must keep the fail-closed remote-web-ui compatibility adapter.
for required in \
    'rewriteRemoteWebUiLoopback' \
    'id: "@linxin666/dsh-remote-web-ui"' \
    'id: "@linxin666/dsh-web-all"' \
    'remote-web-ui: pair flow + heartbeats' \
    'remote-web-ui: remote desktop channel' \
    'const loopback = ctx.get("connection")?.isLoopback ?? true;' \
    'if (isLoopbackHostname(window.location.hostname)) return false;' \
    'if (isLoopbackHostname(hostname)) return false;'
do
    contains "$GATEWAY_PROXY" "$required" 'The fnOS gateway must keep the exact fail-closed remote-web-ui desktop compatibility adapter.'
done

# The fnOS gateway must keep the WebSocket resilience adapter.
for required in \
    'rewriteBetterSidebarWebSocketResilience' \
    'dsh-fnos-better-sidebar-ws' \
    '/sidebar/ws/agent-terminals' \
    '/sidebar/ws/agent-opens' \
    'failures = 0;' \
    'socket.send(\"ping\")' \
    '}, 25000);' \
    'window.clearInterval(keepAlive)'
do
    contains "$GATEWAY_PROXY" "$required" 'The fnOS gateway must keep the fail-closed dsh-better-sidebar WebSocket resilience adapter.'
done

# The packaged fnOS opener must provide a bounded Web carrier on fresh install and upgrade.
for required in \
    '/open-in-app/apps' \
    '/open-in-app/open' \
    '/__fnos/export-session' \
    '/api/session.export' \
    'openFileManager' \
    'payload.app !== FILE_MANAGER_APP_ID' \
    'isEmbeddedHost()' \
    'withWebCarrierUserAgent' \
    'getOrCreateSdk' \
    'primeSdk()' \
    'FNAppVer' \
    'SDK_READY_TIMEOUT_MS' \
    'fnosFileManagerAppsResponse(embedded)' \
    'SIDEBAR_OPEN_EXTERNAL_PATH' \
    'installSidebarOpenExternalAdapter' \
    'parentOfPath' \
    'revealOpen' \
    'openErrorResponse'
do
    contains "$FNOS_OPEN_ENHANCER" "$required" 'The packaged fnOS opener must keep the bounded open-in-app Web carrier contract.'
done
for forbidden in \
    'data-presented-file' \
    'readCardOpenButton' \
    'stopImmediatePropagation'
do
    not_contains "$FNOS_OPEN_ENHANCER" "$forbidden" \
        'The fnOS adapter must not intercept the native presented-file Sidebar action.'
done
contains "$GATEWAY_PROXY" 'serveLocalJavaScript(response, FNOS_OPEN_ENHANCER_FILE, "no-store")' \
    'The gateway must serve the packaged fnOS opener on every startup.'
contains "$GATEWAY_PROXY" 'statProbeIsDirectory' \
    'The gateway must keep the read-only directory probe for the reveal adapter.'
contains "$GATEWAY_PROXY" 'PATH_STAT_PATH' \
    'The gateway must route the __fnos/stat probe endpoint.'
for callback in "$INSTALL_CALLBACK" "$UPGRADE_CALLBACK"; do
    not_contains "$callback" 'fnos-open-enhancer' \
        'The OpenInAppAction fix must come from app.tgz instead of lifecycle-time patching.'
done

# The authenticated, bounded Session ZIP export route must stay in place.
for required in \
    'SESSION_EXPORT_PATH' \
    'SESSION_EXPORT_UPSTREAM_PATH' \
    'SESSION_EXPORT_MAX_BYTES' \
    'validateSessionExportPayload' \
    'upstream session export was not a ZIP archive'
do
    contains "$GATEWAY_PROXY" "$required" 'The fnOS gateway must keep the authenticated, bounded Session ZIP export route.'
done

# The opener must expose both package shares and user-authorized paths.
contains "$GATEWAY_PROXY" 'TRIM_DATA_SHARE_PATHS' \
    'The fnOS opener must include both package shares and user-authorized paths.'
contains "$GATEWAY_PROXY" 'TRIM_DATA_ACCESSIBLE_PATHS' \
    'The fnOS opener must include both package shares and user-authorized paths.'

# The visible-root configuration reader must consume the normalized root list.
awk 'visible_root_capture != 0 || index($0, "function readFnosEnvConfig(") > 0 {
        visible_root_capture = 1
        print
        if (index($0, "return {") > 0) { exit }
    }' "$GATEWAY_PROXY" | LC_ALL=C grep -q 'visibleRoots\.includes' ||
    fail 'The package must use TRIM_PKGHOME/.dsh as DSH_HOME and expose the normalized package root (visibleRoots.includes not found in readFnosEnvConfig).'

# The package must use TRIM_PKGHOME/.dsh as DSH_HOME.
matches "$CONFIG_COMMON" 'validate_package_home\(\)' 'The package must use TRIM_PKGHOME/.dsh as DSH_HOME.'
matches "$CONFIG_COMMON" 'ensure_dsh_home\(\)' 'The package must use TRIM_PKGHOME/.dsh as DSH_HOME.'
matches "$CONFIG_COMMON" 'ensure_shell_state\(\)' 'The package must keep the persistent shell state contract.'
matches "$CONFIG_COMMON" 'shell_state_root\(\)' 'The package must keep the persistent shell state contract.'
matches "$MAIN" 'unset DSH_ADDITIONAL_WRITABLE_ROOTS DSH_PERMISSION_MODE' 'The package must use TRIM_PKGHOME/.dsh as DSH_HOME.'
matches "$MAIN" 'DSH_HOME="\$\{TRIM_PKGHOME\}/\.dsh"' 'The package must use TRIM_PKGHOME/.dsh as DSH_HOME.'
matches "$MAIN" 'HOME="\$TRIM_PKGHOME"' 'The package must use TRIM_PKGHOME/.dsh as DSH_HOME.'
matches "$MAIN" 'HISTFILE="\$SHELL_HISTORY_FILE"' 'The package must keep the persistent shell state contract.'
matches "$MAIN" 'XDG_STATE_HOME="\$SHELL_XDG_STATE_HOME"' 'The package must keep the persistent shell state contract.'
matches "$MAIN" 'XDG_CACHE_HOME="\$SHELL_XDG_CACHE_HOME"' 'The package must keep the persistent shell state contract.'
matches "$MAIN" 'XDG_DATA_HOME="\$SHELL_XDG_DATA_HOME"' 'The package must keep the persistent shell state contract.'
matches "$INSTALL_CALLBACK" 'ensure_shell_state "\$TRIM_PKGVAR"' 'The installer must initialize the persistent shell state.'
matches "$UPGRADE_CALLBACK" 'ensure_shell_state "\$TRIM_PKGVAR"' 'The upgrade callback must initialize the persistent shell state.'
matches "$DSH_LAUNCHER" 'unset DSH_ADDITIONAL_WRITABLE_ROOTS DSH_PERMISSION_MODE' 'The package must use TRIM_PKGHOME/.dsh as DSH_HOME.'
matches "$GATEWAY_PROXY" 'env\.TRIM_PKGHOME' 'The package must use TRIM_PKGHOME/.dsh as DSH_HOME.'
matches "$GATEWAY_PROXY" 'env\.TRIM_PKGVAR' 'The package must use TRIM_PKGHOME/.dsh as DSH_HOME.'
matches "$GATEWAY_PROXY" 'path\.join\(packageHome, "\.dsh"\)' 'The package must use TRIM_PKGHOME/.dsh as DSH_HOME.'

# The terminal host bridge must export the DSH shell marker.
if [ -f "$TERMINAL_BASH_TS" ]; then
    contains "$TERMINAL_BASH_TS" "DSH_SHELL: '1'" \
        'The terminal host bridge must export the DSH shell marker.'
    VENDOR_STATE='verified'
else
    VENDOR_STATE="skipped (the locked upstream checkout is absent from $REPO_ROOT/.tmp/deepseek-harness-upstream)"
    note_skip "$VENDOR_STATE"
fi

# Startup must expose and validate the application-private launchers.
contains "$MAIN" 'PNPM_BIN="${TRIM_PKGVAR}/bin"' \
    'Lifecycle startup must expose and validate the application-private launchers and fnOS plugin policy.'
matches "$MAIN" 'export PATH="\$\{PNPM_BIN\}:\$\{NODE_RUNTIME_BIN\}:' \
    'Lifecycle startup must expose and validate the application-private launchers and fnOS plugin policy.'
contains "$MAIN" '[ ! -x "$PNPM_LAUNCHER" ]' \
    'Lifecycle startup must expose and validate the application-private launchers and fnOS plugin policy.'
contains "$MAIN" '[ ! -x "$DSH_LAUNCHER" ]' \
    'Lifecycle startup must expose and validate the application-private launchers and fnOS plugin policy.'
contains "$MAIN" 'export DSH_FNOS_PLUGIN_POLICY=1' \
    'Lifecycle startup must expose and validate the application-private launchers and fnOS plugin policy.'

# Both startup paths must expose the packaged bundled skill root.
contains "$MAIN" 'BUNDLED_SKILL_DIR="${TRIM_APPDEST}/builtin-skills"' \
    'Both App Center startup and the device dsh launcher must expose the packaged bundled skill root.'
matches "$MAIN" 'BUNDLED_MAINTENANCE_SKILL="\$\{BUNDLED_SKILL_DIR\}/dsh-maintenance/SKILL\.md"' \
    'Both App Center startup and the device dsh launcher must expose the packaged bundled skill root.'
matches "$MAIN" 'BUNDLED_SKILL_CREATOR="\$\{BUNDLED_SKILL_DIR\}/skill-creator/SKILL\.md"' \
    'Both App Center startup and the device dsh launcher must expose the packaged bundled skill root.'
matches "$MAIN" 'export DSH_BUNDLED_SKILL_DIR="\$BUNDLED_SKILL_DIR"' \
    'Both App Center startup and the device dsh launcher must expose the packaged bundled skill root.'
contains "$DSH_LAUNCHER" 'BUNDLED_SKILL_DIR="${APP_DEST}/builtin-skills"' \
    'Both App Center startup and the device dsh launcher must expose the packaged bundled skill root.'
matches "$DSH_LAUNCHER" 'BUNDLED_MAINTENANCE_SKILL="\$\{BUNDLED_SKILL_DIR\}/dsh-maintenance/SKILL\.md"' \
    'Both App Center startup and the device dsh launcher must expose the packaged bundled skill root.'
matches "$DSH_LAUNCHER" 'BUNDLED_SKILL_CREATOR="\$\{BUNDLED_SKILL_DIR\}/skill-creator/SKILL\.md"' \
    'Both App Center startup and the device dsh launcher must expose the packaged bundled skill root.'
matches "$DSH_LAUNCHER" 'export DSH_BUNDLED_SKILL_DIR="\$BUNDLED_SKILL_DIR"' \
    'Both App Center startup and the device dsh launcher must expose the packaged bundled skill root.'

# Bundled skills must not be synchronized through persistent state.
none_matches '\$\{?TRIM_PKGVAR\}?/bundled-skills|DSH_HOME.*/skills/(dsh-maintenance|skill-creator)|setfacl.*skills|chown.*skills' \
    'Lifecycle and launcher code must not synchronize bundled skills through persistent state or manage user-skill ACLs.' \
    "$MAIN" "$DSH_LAUNCHER" "$CONFIG_COMMON" "$INSTALL_CALLBACK" "$UNINSTALL_CALLBACK" "$UPGRADE_INIT" "$UPGRADE_CALLBACK"

# Lifecycle and gateway must complete the private browser-auth handoff.
matches "$MAIN" 'AUTH_TOKEN_FILE="\$\{TRIM_PKGVAR\}/web-auth\.token"' \
    'Lifecycle and gateway must complete the private DSH browser-authentication handoff without logging its token.'
matches "$MAIN" 'DSH_WEB_AUTH_TOKEN_FILE="\$AUTH_TOKEN_FILE"' \
    'Lifecycle and gateway must complete the private DSH browser-authentication handoff without logging its token.'
matches "$MAIN" '--trusted-host 127\.0\.0\.1' \
    'Lifecycle and gateway must complete the private DSH browser-authentication handoff without logging its token.'
matches "$MAIN" 'rm -f -- "\$PORT_FILE" "\$AUTH_TOKEN_FILE"' \
    'Lifecycle and gateway must complete the private DSH browser-authentication handoff without logging its token.'
matches "$GATEWAY_PROXY" 'readLaunchToken' \
    'Lifecycle and gateway must complete the private DSH browser-authentication handoff without logging its token.'
matches "$GATEWAY_PROXY" 'tokenExchangePath' \
    'Lifecycle and gateway must complete the private DSH browser-authentication handoff without logging its token.'
matches "$GATEWAY_PROXY" 'backendAuthCookieName' \
    'Lifecycle and gateway must complete the private DSH browser-authentication handoff without logging its token.'

# Retained Web profiles must use the managed token handoff, not --no-open.
not_matches "$MAIN" '^[[:space:]]*(nohup[[:space:]]+)?(env[[:space:]]+\\[[:space:]]*)?.*\$DSH_ENTRY.*--no-open' \
    'Lifecycle startup must rely on the managed token handoff instead of passing --no-open to retained Web profiles.'

# The device launcher must be atomically installed with a controlled Node 24
# environment.
matches "$CONFIG_COMMON" 'install_dsh_launcher\(\)' \
    'The supported dsh device launcher must be atomically installed with a controlled Node 24 environment.'
matches "$CONFIG_COMMON" 'chmod 700 "\$temporary"' \
    'The supported dsh device launcher must be atomically installed with a controlled Node 24 environment.'
matches "$INSTALL_CALLBACK" 'install_dsh_launcher "\$TRIM_APPDEST" "\$TRIM_PKGVAR"' \
    'The supported dsh device launcher must be atomically installed with a controlled Node 24 environment.'
matches "$UPGRADE_CALLBACK" 'install_dsh_launcher "\$TRIM_APPDEST" "\$TRIM_PKGVAR"' \
    'The supported dsh device launcher must be atomically installed with a controlled Node 24 environment.'
matches "$DSH_LAUNCHER" 'APP_DEST="/var/apps/\$\{APP_NAME\}/target"' \
    'The supported dsh device launcher must be atomically installed with a controlled Node 24 environment.'
matches "$DSH_LAUNCHER" 'DSH_HOME="\$\{PKG_HOME\}/\.dsh"' \
    'The supported dsh device launcher must be atomically installed with a controlled Node 24 environment.'
matches "$DSH_LAUNCHER" 'DSH_FNOS_PLUGIN_POLICY=1' \
    'The supported dsh device launcher must be atomically installed with a controlled Node 24 environment.'
matches "$DSH_LAUNCHER" 'PATH="\$\{SCRIPT_DIR\}:\$\{NODE_RUNTIME_BIN\}:/usr/local/bin:/usr/bin:/bin"' \
    'The supported dsh device launcher must be atomically installed with a controlled Node 24 environment.'

# Upgrade hooks must stop and validate the package without migration backups.
not_matches "$CONFIG_COMMON" \
    'stage_packaged_runtime_for_upgrade|materialize_pending_packaged_runtime|stage_profile_manifest_for_upgrade|stage_settings_document_for_upgrade|restore_staged_profile_manifest|restore_staged_settings_document|has_pending_packaged_runtime_upgrade|restore_pending_packaged_runtime|commit_packaged_runtime_upgrade|upgrade-runtime-backup' \
    'Upgrade hooks must stop and validate the package without creating migration backups.'
not_matches "$UPGRADE_INIT" 'stage_packaged_runtime_for_upgrade|restore_pending_packaged_runtime' \
    'Upgrade hooks must stop and validate the package without creating migration backups.'
not_matches "$UPGRADE_CALLBACK" 'materialize_pending_packaged_runtime|migrate_profile_conflicts|upgrade-runtime-backup' \
    'Upgrade hooks must stop and validate the package without creating migration backups.'
not_matches "$MAIN" \
    'start_service_with_upgrade_recovery|has_pending_packaged_runtime_upgrade|restore_pending_packaged_runtime|commit_packaged_runtime_upgrade' \
    'Upgrade hooks must stop and validate the package without creating migration backups.'

# The bundled Landlock launcher must be restored and functionally verified.
matches "$CONFIG_COMMON" 'prepare_landlock_launcher\(\)' \
    'Lifecycle scripts must restore and functionally verify the bundled Landlock launcher.'
matches "$CONFIG_COMMON" 'chmod 0755 "\$launcher"' \
    'Lifecycle scripts must restore and functionally verify the bundled Landlock launcher.'
matches "$INSTALL_CALLBACK" 'prepare_landlock_launcher "\$TRIM_APPDEST"' \
    'Lifecycle scripts must restore and functionally verify the bundled Landlock launcher.'
matches "$UPGRADE_CALLBACK" 'prepare_landlock_launcher "\$TRIM_APPDEST"' \
    'Lifecycle scripts must restore and functionally verify the bundled Landlock launcher.'
matches "$MAIN" 'LANDLOCK_LAUNCHER="\$\{TRIM_APPDEST\}/server/node_modules/@deepseek-ai/node-addon-system-linux-x64/bin/landlock-run"' \
    'Lifecycle scripts must restore and functionally verify the bundled Landlock launcher.'
matches "$MAIN" 'landlock_probe=\$\("\$LANDLOCK_LAUNCHER" --probe' \
    'Lifecycle scripts must restore and functionally verify the bundled Landlock launcher.'
matches "$MAIN" 'landlock: fully enforced' \
    'Lifecycle scripts must restore and functionally verify the bundled Landlock launcher.'
matches "$MAIN" 'landlock: partially enforced \(older ABI\)' \
    'Lifecycle scripts must restore and functionally verify the bundled Landlock launcher.'

# The selected loopback port must travel only through the DSH CLI.
matches "$MAIN" 'web[[:space:]]+--port[[:space:]]+"\$PORT"[[:space:]]+--trusted-host[[:space:]]+127\.0\.0\.1' \
    'Lifecycle startup must pass the selected loopback port only through the DSH CLI.'

# Proxy activation must stay out of the lifecycle shell environment.
not_matches "$MAIN" '\b(NODE_OPTIONS|NODE_USE_ENV_PROXY)\b' \
    'Proxy activation must not use global Node options or export proxy variables from the lifecycle shell.'
not_matches "$MAIN" '\bexport[[:space:]]+(HTTP_PROXY|HTTPS_PROXY|http_proxy|https_proxy|NO_PROXY|no_proxy|npm_config_proxy|npm_config_https_proxy|npm_config_noproxy)\b' \
    'Proxy activation must not use global Node options or export proxy variables from the lifecycle shell.'

# Configured proxies must be gated by an explicit capability probe.
seq_match "$MAIN" 'validate_proxy_runtime()' '[ -n "$PROXY_URL" ] || return 0' '--help' "grep -Fq -- '--use-env-proxy'" ||
    fail 'Configured proxies must be gated by an explicit Node --use-env-proxy capability check.'

for proxy_variable in HTTP_PROXY HTTPS_PROXY http_proxy https_proxy npm_config_proxy npm_config_https_proxy; do
    contains "$MAIN" "      ${proxy_variable}=\"\$PROXY_URL\" \\" \
        "The DSH launch environment is missing $proxy_variable."
done
for no_proxy_variable in NO_PROXY no_proxy npm_config_noproxy; do
    contains "$MAIN" "      ${no_proxy_variable}=\"127.0.0.1,localhost\" \\" \
        "The DSH launch environment is missing the loopback exclusion $no_proxy_variable."
done
matches "$MAIN" '^[[:space:]]+"\$NODE_BIN" --use-env-proxy "\$DSH_ENTRY" web --port "\$PORT" --trusted-host 127\.0\.0\.1' \
    'The configured-proxy DSH command must enable Node environment proxy support.'
matches "$MAIN" '^[[:space:]]+start_owned_group "\$PID_FILE" "\$NODE_BIN" "\$DSH_ENTRY" web --port "\$PORT" --trusted-host 127\.0\.0\.1' \
    'The no-proxy DSH command must remain free of the proxy switch and injected environment.'

# Startup must export a controlled bash-or-sh terminal shell.
seq_match "$MAIN" 'select_terminal_shell() {' '[ -x /bin/bash ]' 'SHELL=/bin/bash' '[ -x /bin/sh ]' 'SHELL=/bin/sh' 'export SHELL' '}' ||
    fail 'Lifecycle startup must export a controlled bash-or-sh terminal shell before starting DSH.'
seq_match "$MAIN" 'mkdir -p "$TRIM_PKGVAR"' 'ensure_shell_state "$TRIM_PKGVAR"' 'select_terminal_shell || return 1' 'start_dsh_process' ||
    fail 'Lifecycle startup must export a controlled bash-or-sh terminal shell before starting DSH.'

# Terminal compatibility must not make the package account login-capable
# (case-insensitive, mirroring the PowerShell (?i) match).
if LC_ALL=C grep -qiE -- '(/etc/passwd|\bchsh\b|\busermod\b)' "$MAIN"; then
    fail 'Terminal compatibility must not make the fnOS package account login-capable.'
fi

# --- runtime.lock.json -------------------------------------------------------
RUNTIME_LOCK="$PROJECT/runtime.lock.json"
SERVER_MARKER="$PROJECT/app/server/package.json"
if [ -n "$JSON_TOOL" ]; then
    assert_eq "$(json_get "$RUNTIME_LOCK" 'data["schema"]')" '5' \
        'runtime.lock.json contains an invalid official source lock (schema).'
    assert_eq "$(json_get "$RUNTIME_LOCK" 'data["upstream_repository"]')" \
        'https://github.com/deepseek-ai/deepseek-harness.git' \
        'runtime.lock.json contains an invalid official source lock (upstream_repository).'
    assert_ere "$(json_get "$RUNTIME_LOCK" 'data["upstream_commit"]')" '^[0-9a-f]{40}$' \
        'runtime.lock.json contains an invalid official source lock (upstream_commit).'
    assert_ere "$(json_get "$RUNTIME_LOCK" 'data["upstream_tree"]')" '^[0-9a-f]{40}$' \
        'runtime.lock.json contains an invalid official source lock (upstream_tree).'
    assert_ere "$(json_get "$RUNTIME_LOCK" 'data["pnpm_lock_sha256"]')" '^[0-9a-f]{64}$' \
        'runtime.lock.json contains an invalid official source lock (pnpm_lock_sha256).'
    assert_ere "$(json_get "$RUNTIME_LOCK" 'data["cli_package_sha256"]')" '^[0-9a-f]{64}$' \
        'runtime.lock.json contains an invalid official source lock (cli_package_sha256).'
    assert_eq "$(json_get "$RUNTIME_LOCK" 'data["target"]')" 'linux-x64-gnu' \
        'runtime.lock.json contains an invalid official source lock (target).'
    assert_eq "$(json_get "$RUNTIME_LOCK" 'data["platform"]')" 'x86' \
        'runtime.lock.json contains an invalid official source lock (platform).'
    assert_eq "$(json_get "$RUNTIME_LOCK" 'data["workspace_closure_algorithm"]')" '2' \
        'runtime.lock.json contains an invalid official source lock (workspace_closure_algorithm).'

    # The source runtime marker must use the locked official DSH version.
    assert_eq "$(json_get "$SERVER_MARKER" 'data["dependencies"]["@deepseek-ai/dsh"]')" \
        "$(json_get "$RUNTIME_LOCK" 'data["dsh_version"]')" \
        'The source runtime marker must use the locked official DSH version.'

    # --- locked source patches ----------------------------------------------
    assert_eq "$(json_get "$RUNTIME_LOCK" 'len(data["source_patches"])')" '5' \
        'runtime.lock.json must contain exactly five ordered source patches.'
    source_patch_index=0
    while [ "$source_patch_index" -lt 5 ]; do
        case "$source_patch_index" in
            0) patch_slug='0002-dsh-plugin-profile-scoped-management' ;;
            1) patch_slug='0004-web-app-private-auth-token-handoff' ;;
            2) patch_slug='0007-attachment-storage-respect-access-boundary' ;;
            3) patch_slug='0008-fnos-transport-defaults' ;;
            4) patch_slug='0009-dsh-file-upload-agent-resolver-release' ;;
        esac
        case "$source_patch_index" in
            0) patch_sha='955c619b25940b37f91e31b23b0c7f9ced89159e93edc9d648f7686fe1db05b8' ;;
            1) patch_sha='2d0042a10d0b65962309a7abe750d9b73ae1205ccc8398df6b09cd3ebafeb9ad' ;;
            2) patch_sha='592a2e95d8421a65f153b8565036c2b76e8db265b5d02aea1ce73a01033c250c' ;;
            3) patch_sha='cb37de2416c84ddb48239d000cd27d00c9431825d31472e21d767ca5b6a90a12' ;;
            4) patch_sha='3742e064bde2a94e9afca411e96b44f540a6232d3bb3b4872528013baa2f04f0' ;;
        esac
        case "$source_patch_index" in
            0) patch_test_target='packages/boot/plugin-manager/tests/operations.spec.ts' ;;
            1) patch_test_target='packages/bundle/web-app/tests/web-app.spec.ts' ;;
            2) patch_test_target='packages/attachment/attachment-local/tests/store.spec.ts' ;;
            3) patch_test_target='packages/api/gateway/tests/gateway-stream.host.spec.ts packages/client/connection/tests/recovery-config.client.spec.ts' ;;
            4) patch_test_target='packages/client/file-upload/tests/file-upload-resolver-release.host.spec.ts' ;;
        esac
        assert_eq "$(json_get "$RUNTIME_LOCK" "data[\"source_patches\"][$source_patch_index][\"path\"]")" \
            "patches/$patch_slug.patch" \
            "runtime.lock.json contains an invalid or out-of-order source patch lock at index $source_patch_index."
        assert_eq "$(json_get "$RUNTIME_LOCK" "data[\"source_patches\"][$source_patch_index][\"artifact_path\"]")" \
            "source-patches/$patch_slug.patch" \
            "runtime.lock.json contains an invalid or out-of-order source patch lock at index $source_patch_index."
        assert_eq "$(json_get "$RUNTIME_LOCK" "data[\"source_patches\"][$source_patch_index][\"sha256\"]")" \
            "$patch_sha" \
            "runtime.lock.json contains an invalid or out-of-order source patch lock at index $source_patch_index."
        assert_eq "$(json_get "$RUNTIME_LOCK" "data[\"source_patches\"][$source_patch_index][\"test_target\"]")" \
            "$patch_test_target" \
            "runtime.lock.json contains an invalid or out-of-order source patch lock at index $source_patch_index."
        source_patch="$PROJECT/patches/$patch_slug.patch"
        require_file "$source_patch" "A locked source patch is missing: $patch_slug.patch"
        assert_eq "$(sha256_of "$source_patch")" "$patch_sha" \
            "Source patch hash does not match runtime.lock.json: $patch_slug.patch"
        source_patch_index=$((source_patch_index + 1))
    done

    # --- pnpm supply-chain lock ---------------------------------------------
    pnpm_version=$(json_get "$RUNTIME_LOCK" 'data["pnpm"]["version"]')
    assert_ere "$pnpm_version" '^[0-9]+\.[0-9]+\.[0-9]+$' \
        'runtime.lock.json contains an invalid pnpm supply-chain lock (version).'
    assert_eq "$(json_get "$RUNTIME_LOCK" 'data["pnpm"]["asset_name"]')" "pnpm-$pnpm_version.tgz" \
        'runtime.lock.json contains an invalid pnpm supply-chain lock (asset_name).'
    assert_ere "$(json_get "$RUNTIME_LOCK" 'data["pnpm"]["asset_sha256"]')" '^[0-9a-f]{64}$' \
        'runtime.lock.json contains an invalid pnpm supply-chain lock (asset_sha256).'
    assert_ere "$(json_get "$RUNTIME_LOCK" 'data["pnpm"]["integrity"]')" '^sha512-[A-Za-z0-9+/]+={0,2}$' \
        'runtime.lock.json contains an invalid pnpm supply-chain lock (integrity).'

    # --- landlock-run supply-chain lock -------------------------------------
    landlock_version=$(json_get "$RUNTIME_LOCK" 'data["landlock_run"]["version"]')
    assert_eq "$(json_get "$RUNTIME_LOCK" 'data["landlock_run"]["package_name"]')" \
        '@deepseek-ai/node-addon-system-linux-x64' \
        'runtime.lock.json contains an invalid landlock-run supply-chain lock (package_name).'
    assert_ere "$landlock_version" '^[0-9]+\.[0-9]+\.[0-9]+$' \
        'runtime.lock.json contains an invalid landlock-run supply-chain lock (version).'
    assert_eq "$(json_get "$RUNTIME_LOCK" 'data["landlock_run"]["asset_name"]')" \
        "node-addon-system-linux-x64-$landlock_version.tgz" \
        'runtime.lock.json contains an invalid landlock-run supply-chain lock (asset_name).'
    assert_eq "$(json_get "$RUNTIME_LOCK" 'data["landlock_run"]["asset_url"]')" \
        "https://registry.npmjs.org/@deepseek-ai/node-addon-system-linux-x64/-/node-addon-system-linux-x64-$landlock_version.tgz" \
        'runtime.lock.json contains an invalid landlock-run supply-chain lock (asset_url).'
    assert_ere "$(json_get "$RUNTIME_LOCK" 'data["landlock_run"]["asset_sha256"]')" '^[0-9a-f]{64}$' \
        'runtime.lock.json contains an invalid landlock-run supply-chain lock (asset_sha256).'
    assert_ere "$(json_get "$RUNTIME_LOCK" 'data["landlock_run"]["integrity"]')" '^sha512-[A-Za-z0-9+/]+={0,2}$' \
        'runtime.lock.json contains an invalid landlock-run supply-chain lock (integrity).'
    assert_eq "$(json_get "$RUNTIME_LOCK" 'data["landlock_run"]["binary_path"]')" 'bin/landlock-run' \
        'runtime.lock.json contains an invalid landlock-run supply-chain lock (binary_path).'
else
    note_skip 'JSON field contracts skipped: python3 is not available.'
fi

# --- vendored fnOS JS SDK ----------------------------------------------------
TRIM_SDK_LOCK="$PROJECT/app/web/trim-web-app.lock.json"
require_file "$TRIM_SDK_LOCK" 'The vendored fnOS JS SDK lock is missing.'
json_valid "$TRIM_SDK_LOCK" || fail 'The vendored fnOS JS SDK lock is not valid JSON.'
if [ -n "$JSON_TOOL" ]; then
    assert_eq "$(json_get "$TRIM_SDK_LOCK" 'data["source_package"]["name"]')" '@trimjs/web-app' \
        'The vendored fnOS JS SDK lock is invalid (source package name).'
    assert_ere "$(json_get "$TRIM_SDK_LOCK" 'data["source_package"]["version"]')" '^[0-9]+\.[0-9]+\.[0-9]+$' \
        'The vendored fnOS JS SDK lock is invalid (source package version).'
    assert_ere "$(json_get "$TRIM_SDK_LOCK" 'data["artifact_sha256"]')" '^[0-9a-f]{64}$' \
        'The vendored fnOS JS SDK lock is invalid (artifact_sha256).'
    trim_sdk_artifact="$PROJECT/$(json_get "$TRIM_SDK_LOCK" 'data["artifact_path"]')"
    require_file "$trim_sdk_artifact" 'The vendored fnOS JS SDK artifact is missing.'
    assert_eq "$(sha256_of "$trim_sdk_artifact")" \
        "$(json_get "$TRIM_SDK_LOCK" 'data["artifact_sha256"]')" \
        'The vendored fnOS JS SDK artifact does not match its lock (SHA-256).'
    assert_eq "$(file_bytes "$trim_sdk_artifact")" \
        "$(json_get "$TRIM_SDK_LOCK" 'data["artifact_bytes"]')" \
        'The vendored fnOS JS SDK artifact does not match its lock (byte count).'
fi

# --- locked upstream submodule ----------------------------------------------
if [ -f "$GITMODULES" ] && command -v git >/dev/null 2>&1 && git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    submodule_path=$(git config -f "$GITMODULES" --get 'submodule.deepseek-harness.path' 2>/dev/null) ||
        fail 'The DeepSeek Harness submodule path is invalid.'
    assert_eq "$submodule_path" 'vendor/upstream/deepseek-harness' \
        'The DeepSeek Harness submodule path is invalid.'
    submodule_url=$(git config -f "$GITMODULES" --get 'submodule.deepseek-harness.url' 2>/dev/null) ||
        fail 'The DeepSeek Harness submodule URL does not match runtime.lock.json.'
    assert_eq "$submodule_url" "$(json_get "$RUNTIME_LOCK" 'data["upstream_repository"]')" \
        'The DeepSeek Harness submodule URL does not match runtime.lock.json.'
    if git config -f "$GITMODULES" --get 'submodule.deepseek-harness.branch' >/dev/null 2>&1; then
        fail 'The DeepSeek Harness submodule must not track a branch.'
    fi
    gitlink=$(git -C "$REPO_ROOT" ls-files --stage -- 'vendor/upstream/deepseek-harness' | head -n 1 | tr -s ' ')
    case "$gitlink" in
        '160000 '*) : ;;
        *) fail "The DeepSeek Harness gitlink does not match runtime.lock.json (got [$gitlink])." ;;
    esac
    gitlink_commit=$(printf '%s\n' "$gitlink" | awk '{print $2}')
    assert_ere "$gitlink_commit" '^[0-9a-f]{40}$' \
        'The DeepSeek Harness gitlink does not match runtime.lock.json.'
    assert_eq "$gitlink_commit" "$(json_get "$RUNTIME_LOCK" 'data["upstream_commit"]')" \
        'The DeepSeek Harness gitlink does not match runtime.lock.json.'
    GIT_LOCK_STATE='verified'
else
    GIT_LOCK_STATE="skipped (no git work tree with .gitmodules under $REPO_ROOT)"
    note_skip "$GIT_LOCK_STATE"
fi

# --- FPK build source contracts ---------------------------------------------
# The build must consume the locked official Git source without an upstream FPK.
not_matches "$BUILD_FPK" '\bRuntimeFpk\b' \
    'The build must consume the locked official Git source without an upstream FPK.'
not_matches "$BUILD_FPK" 'techysy/deepseek-harness-fnos' \
    'The build must consume the locked official Git source without an upstream FPK.'
not_matches "$BUILD_FPK" '\$sourceCache' \
    'The build must consume the locked official Git source without an upstream FPK.'
for required in \
    'resolve-upstream-source.sh' \
    'cat-file blob HEAD:pnpm-lock.yaml' \
    'cat-file blob HEAD:apps/cli/package.json' \
    'build-source-runtime.sh' \
    'package-linux.sh' \
    'Source patch SHA-256 mismatch' \
    'source-patches/0002-dsh-plugin-profile-scoped-management.patch' \
    'source-patches/0004-web-app-private-auth-token-handoff.patch' \
    'source-patches/0007-attachment-storage-respect-access-boundary.patch' \
    'source-patches/0008-fnos-transport-defaults.patch' \
    'source-patches/0009-dsh-file-upload-agent-resolver-release.patch' \
    'check-summary-client.mjs' \
    'summary-client-compat.js' \
    'gateway-websocket.js' \
    '${app_name}_${version}_${LOCK_PLATFORM}.fpk'
do
    contains "$BUILD_FPK" "$required" \
        'The build must consume the locked official Git source without an upstream FPK.'
done
seq_match "$BUILD_FPK" 'git' 'archive' ||
    fail 'The build must consume the locked official Git source without an upstream FPK (git archive not found).'

for required in \
    'node-linker=hoisted' \
    'pnpm_bin_root=${work_root}/pnpm-bin' \
    'exec node "%s" "$@"' \
    'export PATH="$pnpm_bin_root:$PATH"' \
    'GIT_CEILING_DIRECTORIES' \
    '<source-commit> <dsh-version>' \
    '(<source.patch> <patch-sha256> <test-target>)...' \
    '${#source_commit}' \
    'DSH_BUILD_CLIENT_PROFILE=official DSH_CLIENT_COMMIT_HASH="$source_commit" pnpm run build' \
    'git apply --check --whitespace=error-all "$source_patch"' \
    "IFS=' ' read -r -a test_targets" \
    'pnpm exec vitest run "${test_targets[@]}"' \
    'A locked source patch test target must be under packages/' \
    'vitest run --config vitest.e2e.config.ts packages/sandbox/sandbox-local/tests/landlock.e2e.ts' \
    'vitest run apps/cli/tests/args.spec.ts' \
    'run_vitest_with_retries 3 --config vitest.e2e.config.ts apps/cli/tests/built-bin.e2e.ts' \
    'generate-source-runtime.mjs' \
    'prune-source-runtime.mjs' \
    'materialize-workspace-links.sh' \
    '<landlock.tgz>' \
    'node_modules/node-pty/prebuilds/linux-x64/pty.node'
do
    contains "$SOURCE_BUILD" "$required" \
        'The build must consume the locked official Git source without an upstream FPK.'
done
matches "$SOURCE_BUILD" '\$\{#source_commit\}.*-eq 40' \
    'The build must consume the locked official Git source without an upstream FPK (locked source commit validation).'
matches "$SOURCE_BUILD" 'install -D -m 0755.*landlock-run' \
    'The build must consume the locked official Git source without an upstream FPK (landlock install).'
seq_match "$SOURCE_BUILD" 'generate-source-runtime.mjs' 'install --prefer-offline --frozen-lockfile --ignore-scripts' ||
    fail 'The source build must generate the runtime before the frozen install with metadata fallback.'
not_contains "$SOURCE_BUILD" 'install --offline' \
    'The generated runtime importer must permit missing registry metadata to be fetched on clean CI runners.'
seq_match "$SOURCE_BUILD" 'materialize-workspace-links.sh' 'chmod 0755 "$landlock_launcher"' ||
    fail 'The source build must materialize workspace links before installing the Landlock launcher.'
matches "$SOURCE_BUILD" 'find "\$sharp_package_lib" -maxdepth 1 -type f -name ' "\*\.node'" ||
    fail 'The source build must collect the sharp platform binaries.'
not_contains "$SOURCE_BUILD" '--no-frozen-lockfile' \
    'The source build must not relax the frozen lockfile contract.'
matches "$SOURCE_BUILD" '"\$landlock_launcher" --probe' \
    'The source build must probe the bundled Landlock launcher.'
no_frozen_count=$(count_matches "$SOURCE_BUILD" '--no-frozen-lockfile')
assert_eq "$no_frozen_count" '0' \
    'The source build must not relax the frozen lockfile contract.'
for required in \
    'typescript_sources' \
    'source_maps' \
    'development_directories' \
    'unsupported_platform_prebuilds' \
    'node_modules/node-pty/prebuilds/linux-x64/pty.node'
do
    contains "$SOURCE_PRUNER" "$required" \
        'The source pruner must drop the reviewed non-runtime payload.'
done
contains "$BUILD_FPK" 'Final app.tgz contains unsupported node-pty prebuilds' \
    'The build must reject unsupported node-pty prebuilds in the final payload.'
contains "$BUILD_FPK" 'node_modules/@img/sharp-linux-x64/lib' \
    'The FPK build must record the sharp platform library payload.'
contains "$BUILD_FPK" "find \"\$sharp_package_lib\" -maxdepth 1 -type f -name '*.node'" \
    'The FPK build must record the sharp native payload filter.'
contains "$BUILD_FPK" 'nested-entries.txt' \
    'The FPK build must inspect nested runtime payload entries.'
contains "$BUILD_FPK" '"$PACKAGE_STAGE" "$SOURCE_RUNTIME_ARCHIVE" "$fnpack_path"' \
    'The FPK build must carry the locked source runtime inputs.'
for required in \
    'process.argv.slice(2)' \
    'assertKnownChangesSummaryClient' \
    'rewriteChangesSummaryClient' \
    'new vm.Script(adapted' \
    'summary-client build gate passed'
do
    contains "$PROJECT/scripts/check-summary-client.mjs" "$required" \
        'The shared summary-client compatibility checker must validate arguments, shapes, and rewritten script syntax.'
done

# The source resolver must enforce the clean pinned upstream submodule contract.
for required in \
    "submodule_path='vendor/upstream/deepseek-harness'" \
    'initialize_locked_submodule()' \
    'clone --no-checkout' \
    'checkout --detach' \
    'ls-files --stage' \
    'must pin a commit without a tracking branch' \
    'must be clean because local changes are not build inputs'
do
    contains "$SOURCE_RESOLVER" "$required" \
        'The source resolver must enforce the clean pinned upstream submodule contract.'
done
not_matches "$SOURCE_RESOLVER" 'deepseek-harness-source' \
    'The source resolver must enforce the clean pinned upstream submodule contract.'

# The FPK build must verify the locked landlock-run asset and final payload.
for required in \
    "LANDLOCK_TARBALL_ARG=''" \
    'verify_asset_integrity "$resolved_landlock"' \
    'landlock-run tarball' \
    'server/node_modules/@deepseek-ai/node-addon-system-linux-x64/bin/landlock-run' \
    'The final app.tgz strips the landlock-run mode but lifecycle permission repair is missing' \
    'The final app.tgz landlock-run binary differs from the locked official binary'
do
    contains "$BUILD_FPK" "$required" \
        'The FPK build must verify the locked landlock-run asset and final executable payload.'
done

# The native FPK build must validate normalized manifest fields and isolated output.
for required in \
    'manifest_field_pairs()' \
    'Unable to read the staged manifest fields' \
    'Final FPK manifest changed source field' \
    'Final FPK manifest contains unexpected generated fields' \
    '_generated_manifest_fields'
do
    contains "$BUILD_FPK" "$required" \
        'The native FPK build must validate normalized manifest fields plus isolated output.'
done
not_matches "$BUILD_FPK" 'stagedManifestHash' \
    'The native FPK build must validate normalized manifest fields plus isolated output.'
contains "$PACKAGE_LINUX" 'existing_artifacts' \
    'The Linux packaging step must keep isolated output.'
contains "$PACKAGE_LINUX" 'fnpack must produce exactly one FPK' \
    'The Linux packaging step must keep isolated output.'

# The FPK build must emit deterministic provenance and verify every component.
for required in \
    'build_component()' \
    'BUILD_COMPONENT_PATHS' \
    'build-info.json' \
    'source-only server marker' \
    'build provenance identity is invalid' \
    'component differs from build provenance' \
    'STAGED_BUILD_INFO_HASH' \
    'gateway-websocket.js' \
    'summary-client-compat.js' \
    'check-summary-client.mjs' \
    'SUMMARY_CLIENT_CHECKER'
do
    contains "$BUILD_FPK" "$required" \
        'The FPK build must emit deterministic device-readable provenance and invoke the shared summary-client compatibility checker.'
done
contains "$BUILD_FPK" 'require_file "$SUMMARY_CLIENT_CHECKER"' \
    'The FPK build must require the shared summary-client compatibility checker.'
contains "$BUILD_FPK" 'node "$SUMMARY_CLIENT_CHECKER" "$summary_client_compat" "$summary_client_bundle"' \
    'The FPK build must invoke the shared summary-client compatibility checker.'
not_contains "$BUILD_FPK" 'assertKnownChangesSummaryClient' \
    'The FPK build must not inline summary-client compatibility logic.'
not_contains "$BUILD_FPK" 'rewriteChangesSummaryClient' \
    'The FPK build must not inline summary-client compatibility logic.'
not_contains "$BUILD_FPK" 'new vm.Script(adapted' \
    'The FPK build must not inline summary-client compatibility logic.'
seq_match "$BUILD_FPK" 'summary_client_bundle=' 'node "$SUMMARY_CLIENT_CHECKER" "$summary_client_compat" "$summary_client_bundle"' '[ -f "$STAGED_SERVER/node_modules/yaml/package.json" ]' ||
    fail 'The shared summary-client compatibility gate must run after runtime extraction and before packaging checks.'

# The FPK build must record and require the packaged bundled skills.
maintenance_records=$(count_matches "$BUILD_FPK" 'builtin-skills/dsh-maintenance/SKILL.md')
if [ "$maintenance_records" -lt 2 ]; then
    fail "The FPK build must record and require the packaged dsh-maintenance skill (found $maintenance_records occurrence(s))."
fi
not_matches "$BUILD_FPK" "builtin-skills/gateway-route-injection/SKILL\.md|builtin-skills/skill-creator/scripts/[^'\"]+\.ps1|TRIM_PKGVAR.*bundled-skills" \
    'The FPK build must record and require the packaged dsh-maintenance skill and the PowerShell-free skill-creator subset.'
for relative_path in $BUNDLED_SKILL_CREATOR_PATHS; do
    packaged_path="builtin-skills/skill-creator/$relative_path"
    packaged_records=$(count_matches "$BUILD_FPK" "$packaged_path")
    if [ "$packaged_records" -lt 2 ]; then
        fail "The FPK build does not record and require bundled skill-creator file: $relative_path (found $packaged_records occurrence(s))."
    fi
done

# build-info.json must be generated per build, not retained in the source tree.
[ ! -e "$PROJECT/app/build-info.json" ] ||
    fail 'build-info.json must be generated per build instead of retained in the source app tree.'

# The fnOS lifecycle must not disable sandboxing.
not_contains "$MAIN" 'danger-full-access' \
    'The fnOS lifecycle must not disable sandboxing to work around a missing backend.'

# The pnpm launcher must validate stores and pass the selected store plus Node 24
# through the environment.
for required in \
    'TRIM_APPDEST' \
    'TRIM_PKGVAR' \
    'pnpm/bin/pnpm.cjs' \
    'DSH_PLUGIN_STORE_DIR' \
    '.dsh/profiles' \
    '[ -L "$checked_path" ]' \
    '[[:cntrl:]]' \
    'pnpm_config_store_dir="$PNPM_STORE"' \
    'npm_config_proxy' \
    'npm_config_https_proxy' \
    'npm_config_noproxy' \
    'HTTP_PROXY' \
    'HTTPS_PROXY' \
    'NO_PROXY'
do
    contains "$PNPM_LAUNCHER" "$required" \
        'The pnpm launcher must validate stores and pass the selected store plus Node 24 through the environment.'
done
matches "$PNPM_LAUNCHER" 'PATH="\$\{NODE_RUNTIME_BIN\}:' \
    'The pnpm launcher must validate stores and pass the selected store plus Node 24 through the environment.'
not_contains "$PNPM_LAUNCHER" '--store-dir' \
    'The pnpm launcher must pass the store through the environment instead of a command-line switch.'

# --- static audit ------------------------------------------------------------
if [ -f "$AUDIT_SCRIPT" ] && [ -n "$JSON_TOOL" ]; then
    audit_json=$("$BASH_BIN" "$AUDIT_SCRIPT" --project-path "$PROJECT" -Format json) ||
        fail 'fnOS static audit command failed.'
    audit_high=$(printf '%s' "$audit_json" | python3 -c '
import json, sys
data = json.load(sys.stdin)
print(data["summary"]["high"])
') || fail 'Unable to read the fnOS static audit summary.'
    audit_medium=$(printf '%s' "$audit_json" | python3 -c '
import json, sys
data = json.load(sys.stdin)
print(data["summary"]["medium"])
') || fail 'Unable to read the fnOS static audit summary.'
    audit_total=$(printf '%s' "$audit_json" | python3 -c '
import json, sys
data = json.load(sys.stdin)
print(data["summary"]["total"])
') || fail 'Unable to read the fnOS static audit summary.'
    if [ "$audit_high" -gt 0 ]; then
        fail "fnOS static audit reported $audit_high high-severity finding(s)."
    fi
    AUDIT_STATE='passed'
else
    AUDIT_STATE="skipped (static audit needs $AUDIT_SCRIPT and python3)"
    note_skip "$AUDIT_STATE"
    audit_high='unknown'
    audit_medium='unknown'
    audit_total='unknown'
fi

# --- report ------------------------------------------------------------------
printf 'Project=%s\n' "$PROJECT"
printf 'RepositoryRoot=%s\n' "$REPO_ROOT"
printf 'JsonFiles=%s\n' "$json_file_count"
printf 'JsonChecks=%s\n' "${JSON_TOOL:-skipped}"
printf 'ShellFiles=%s\n' "$shell_syntax_count"
printf 'ShellSyntax=%s\n' "${BASH_BIN:-sh}"
printf 'IconChecks=4\n'
printf 'SkillCreatorInventory=matched\n'
printf 'ProxyTests=passed\n'
printf 'LoopbackPortSelectorTests=passed\n'
printf 'ConfigTests=passed\n'
printf 'GitSubmoduleLock=%s\n' "$GIT_LOCK_STATE"
printf 'VendorSourceChecks=%s\n' "$VENDOR_STATE"
printf 'SourceResolverTests=%s\n' "$RESOLVER_STATE"
printf 'StaticAudit=%s\n' "$AUDIT_STATE"
printf 'AuditHigh=%s\n' "$audit_high"
printf 'AuditMedium=%s\n' "$audit_medium"
printf 'AuditFindings=%s\n' "$audit_total"
printf 'Result=passed\n'
