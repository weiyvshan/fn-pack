#!/bin/sh
# Source contract test for the cpa-manager-plus fnOS package.
#
# Mirror of scripts/test-package.ps1 for POSIX hosts (fnOS). Checks the package
# manifest, JSON contracts, default config, lifecycle shell scripts, icons, the
# component lock, migration behavior and lifecycle smoke tests.
#
# Run scripts/prepare-binaries.py before this test, or use build-fpk.sh, which
# prepares the locked cache automatically. Missing or corrupt binaries fail
# explicitly so the real v8 migration test cannot silently disappear.
set -u

PROJECT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# The packaging repository root carries the shared fnpack/audit skill and the
# ignored binary cache.
REPO_ROOT=''
for candidate in "$PROJECT/.." "$PROJECT/../.."; do
    resolved=$(CDPATH= cd -- "$candidate" 2>/dev/null && pwd) || continue
    if [ -d "$resolved/.agents/skills/fnnas-app-creator" ]; then
        REPO_ROOT="$resolved"
        break
    fi
done
[ -n "$REPO_ROOT" ] || REPO_ROOT=$(CDPATH= cd -- "$PROJECT/../.." 2>/dev/null && pwd || printf '%s' "$PROJECT")
JSON_TOOL=''
PNG_AVAILABLE=no

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

# JSON contracts are validated with python3; the checks are reported as skipped
# when the host has no interpreter.
if command -v python3 >/dev/null 2>&1; then
    JSON_TOOL=python3
fi

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

manifest_value() {
    # manifest_value <key>: first "key = value" line wins, matching fnOS parsing.
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$PROJECT/manifest" | head -n 1 | sed 's/[[:space:]]*$//'
}

assert_eq() {
    [ "$1" = "$2" ] || fail "$3 (got [$1], want [$2])"
}

assert_contains() {
    case "$1" in
        *"$2"*) : ;;
        *) fail "$3" ;;
    esac
}

assert_not_contains() {
    case "$1" in
        *"$2"*) fail "$3" ;;
        *) : ;;
    esac
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

port_busy() {
    ss -ltn 2>/dev/null | grep -Eq "[.:]$1[[:space:]]"
}

# --- manifest ----------------------------------------------------------------
for spec in \
    'appname=cpa-manager-plus' \
    'version=1.0.16' \
    'platform=x86' \
    'source=thirdparty' \
    'os_min_version=1.1.8' \
    'ctl_stop=true' \
    'desktop_uidir=ui' \
    'desktop_applaunchname=cpa-manager-plus.main' \
    'service_port=18317' \
    'checkport=false' \
    'disable_authorization_path=true'
do
    key=${spec%%=*}
    want=${spec#*=}
    got=$(manifest_value "$key")
    assert_eq "$got" "$want" "Unexpected manifest value for $key."
done

# --- privilege and resource --------------------------------------------------
[ -f "$PROJECT/config/privilege" ] || fail 'config/privilege is missing.'
[ -f "$PROJECT/config/resource" ] || fail 'config/resource is missing.'
json_valid "$PROJECT/config/privilege" || fail 'config/privilege is not valid JSON.'
json_valid "$PROJECT/config/resource" || fail 'config/resource is not valid JSON.'
if [ -n "$JSON_TOOL" ]; then
    assert_eq "$(json_get "$PROJECT/config/privilege" 'data["defaults"]["run-as"]')" 'package' \
        'The application must run as its package identity.'
    assert_eq "$(json_get "$PROJECT/config/privilege" 'data["username"]')" 'cpa-manager-plus' \
        'Privilege username must match the package contract.'
    assert_eq "$(json_get "$PROJECT/config/privilege" 'data["groupname"]')" 'cpa-manager-plus' \
        'Privilege group must match the package contract.'

    # --- desktop entry ------------------------------------------------------
    assert_eq "$(json_get "$PROJECT/app/ui/config" 'data[".url"]["cpa-manager-plus.main"]["port"]')" '18317' \
        'Desktop entry port differs from the runtime contract.'
    assert_eq "$(json_get "$PROJECT/app/ui/config" 'data[".url"]["cpa-manager-plus.main"]["url"]')" '/management.html' \
        'Desktop entry URL differs from the runtime contract.'
    assert_eq "$(json_get "$PROJECT/app/ui/config" 'data[".url"]["cpa-manager-plus.main"]["allUsers"]')" 'false' \
        'Desktop entry must remain administrator-only.'
    assert_eq "$(json_get "$PROJECT/app/ui/config" 'data[".url"]["cpa-manager-plus.main"]["control"]["accessPerm"]')" 'readonly' \
        'Desktop entry must stay read-only in the launcher.'

    # --- install wizard -----------------------------------------------------
    wizard_fields=$(json_get "$PROJECT/wizard/install" '",".join(field["field"] for field in data[0]["items"] if "field" in field)')
    assert_eq "$wizard_fields" 'wizard_cpamp_admin_key,wizard_cli_api_key' \
        'Install wizard must expose exactly the two planned secret fields.'
    assert_eq "$(json_get "$PROJECT/wizard/install" 'data[0]["items"][0 if data[0]["items"][0].get("field")=="wizard_cpamp_admin_key" else 1]["min"]')" '16' \
        'Administrator key wizard minimum must stay 16 characters.'
    assert_eq "$(json_get "$PROJECT/wizard/install" 'data[0]["items"][0 if data[0]["items"][0].get("field")=="wizard_cpamp_admin_key" else 1]["max"]')" '128' \
        'Administrator key wizard maximum must stay 128 characters.'
    admin_label=$(json_get "$PROJECT/wizard/install" 'data[0]["items"][0 if data[0]["items"][0].get("field")=="wizard_cpamp_admin_key" else 1]["label"]')
    admin_tip=$(json_get "$PROJECT/wizard/install" 'data[0]["items"][0 if data[0]["items"][0].get("field")=="wizard_cpamp_admin_key" else 1]["tip"]')
    assert_contains "$admin_label" '16-128' 'Administrator key length requirement must be visible in the wizard label.'
    assert_contains "$admin_tip" '16-128' 'Administrator key length requirement must be visible in the wizard tip.'

    # --- uninstall wizard ---------------------------------------------------
    assert_eq "$(json_get "$PROJECT/wizard/uninstall" 'data[0]["items"][0]["field"]')" 'delete_data' \
        'Uninstall wizard must expose the delete_data field.'
    assert_eq "$(json_get "$PROJECT/wizard/uninstall" 'data[0]["items"][0]["initValue"]')" 'false' \
        'Uninstall must preserve data by default.'
fi

# --- default CLIProxyAPI config ---------------------------------------------
default_config_path="$PROJECT/app/defaults/cli-proxy-api.yaml"
default_config=$(cat "$default_config_path")
for required in \
    'config-version: 8' \
    'server:' \
    'host: "0.0.0.0"' \
    'port: 8317' \
    'management:' \
    'allow-remote: true' \
    'disable-control-panel: true' \
    'disable-auto-update-panel: true' \
    'access:' \
    'routing:' \
    'oauth:' \
    'observability:' \
    'usage-statistics-enabled: true' \
    'redis-usage-queue-retention-seconds: 3600' \
    'plugins:' \
    '__CPA_MANAGEMENT_KEY__' \
    '__CLI_API_KEY__' \
    '__AUTH_DIR__' \
    '__PLUGIN_DIR__'
do
    assert_contains "$default_config" "$required" "Default CLIProxyAPI config is missing: $required"
done
grep -Eq '^  api-keys:[[:space:]]*$' "$default_config_path" ||
    fail 'Default client keys must live under access.api-keys.'
if grep -Eq '^(host|port|remote-management|api-keys|auth-dir|debug|logging-to-file|usage-statistics-enabled|request-retry):' "$default_config_path"; then
    fail 'Default CLIProxyAPI config contains a legacy top-level field or root client api-keys.'
fi
# The credential time policy plugin is no longer bundled, so no shipped config
# may keep configuring it.
assert_not_contains "$default_config" 'credential-time-policy' \
    'Default CLIProxyAPI config still configures the removed credential time policy plugin.'

# --- lifecycle shell scripts -------------------------------------------------
SHELL_FILES=$(find "$PROJECT/cmd" -type f | sort)
[ -n "$SHELL_FILES" ] || fail 'No lifecycle scripts found under cmd/.'
for script in $SHELL_FILES; do
    name=$(basename -- "$script")
    if ! tr -d '\r' < "$script" | cmp -s - "$script"; then
        fail "Lifecycle script contains CRLF bytes: $name"
    fi
    head -c 9 "$script" | grep -q '^#!/bin/sh$' || fail "Lifecycle script lacks the POSIX sh shebang: $name"
    sh -n "$script" || fail "POSIX shell syntax validation failed: $name"
done

main_text=$(cat "$PROJECT/cmd/main")
for required in \
    'CPA_MANAGER_ADMIN_KEY_FILE=' \
    'CPA_MANAGEMENT_KEY_FILE=' \
    'http://127.0.0.1:8317/healthz' \
    'http://127.0.0.1:18317/health' \
    'readlink "/proc/$pid/exe"' \
    'package_process_binary' \
    'describe_port_owner' \
    '/proc/$pid/cmdline' \
    '/proc/$pid/comm' \
    'acquire_lifecycle_lock' \
    'lifecycle.lock' \
    'wait_for_lifecycle_quiet' \
    'release_lifecycle_lock; exit 143' \
    'process_uid=' \
    'pid_matches_package_binary' \
    'stop_upgrade_services' \
    'wait_for_port_release' \
    'stop-for-upgrade' \
    'RUN_DIR="$CPA_VAR/run"' \
    'return 3'
do
    assert_contains "$main_text" "$required" "Lifecycle contract is missing: $required"
done

# Startup identity race contract: an unexecuted candidate must be waited for
# instead of being declared dead, and cleanup must confirm ownership before it
# signals the candidate.
for required in 'identity_waited' 'stop_verified_pid_waiting'
do
    assert_contains "$main_text" "$required" "Startup race contract is missing: $required"
done
# The old code declared an early exit as soon as the identity check failed; the
# fixed code only reports it once the process is actually gone.
if printf '%s' "$main_text" | grep -q 'pid_matches "$pid" "$expected" || {'; then
    fail 'wait_for_service must not treat a failed identity check as an early exit.'
fi
# The credential time policy plugin is an optional enhancement now: the
# lifecycle must not require it to be present or executable.
if printf '%s' "$main_text" | grep -q '凭证时段策略插件缺失'; then
    fail 'Lifecycle still requires the removed credential time policy plugin.'
fi
if printf '%s' "$main_text" | grep -Eq '(^|[[:space:]])pkill([[:space:]]|$)|(^|[[:space:]])eval([[:space:]]|$)'; then
    fail 'Lifecycle must not use global process cleanup or eval.'
fi
# The CPA manager must not be started through an intermediate env process, which
# is what let the candidate image lag behind the identity check.
if printf '%s' "$main_text" | grep -q 'nohup env'; then
    fail 'CPA Manager Plus must not be launched through an intermediate env wrapper.'
fi
# The unreadable-exe fallback must stay in place. Treating a denied readlink on
# /proc/<pid>/exe as proof of foreign ownership is what left a live CLIProxyAPI
# holding port 8317 during stop and upgrade.
if printf '%s' "$main_text" | grep -q 'process_exe=$(readlink "/proc/$pid/exe" 2>/dev/null) || return 1'; then
    fail 'Lifecycle must not treat an unreadable /proc/<pid>/exe as an unowned process.'
fi
if printf '%s' "$main_text" | grep -q 'basename -- "$process_cmdline")" = "$process_comm"'; then
    fail 'comm must be matched as a prefix because the kernel truncates it.'
fi
assert_contains "$main_text" '${process_leaf#"$process_comm"}' \
    'The fallback must verify the kernel short name against argv[0].'

upgrade_init_text=$(cat "$PROJECT/cmd/upgrade_init")
assert_contains "$upgrade_init_text" 'upgrade_init' 'Upgrade init must call upgrade_init.'
assert_contains "$upgrade_init_text" '"$SCRIPT_DIR/main" stop-for-upgrade' \
    'Upgrade init must stop the old service before target files are replaced.'
upgrade_callback_text=$(cat "$PROJECT/cmd/upgrade_callback")
assert_contains "$upgrade_callback_text" '"$SCRIPT_DIR/main" stop-for-upgrade' \
    'Upgrade callback must stop a stale old service after target replacement as a defense in depth.'
assert_contains "$main_text" '无法停止，拒绝继续操作' 'Service stop must fail when an owned process remains alive.'
assert_contains "$main_text" '端口可能仍被占用' 'Service stop must report a still-busy port.'

installer_text=$(cat "$PROJECT/cmd/installer")
for required in \
    'prepare_binaries' \
    'prepare_plugin_binaries' \
    'credential-time-policy.so' \
    'ensure_cpamp_proxy_management_access' \
    'target_section' \
    'management' \
    'remote-management' \
    'chmod 0755' \
    'chmod 0600' \
    'Preserved existing' \
    'canonical_path' \
    'rm -rf -- "$resolved"' \
    '$TRIM_PKGVAR/cpa-manager-plus/run'
do
    assert_contains "$installer_text" "$required" "Installer contract is missing: $required"
done

# --- icons -------------------------------------------------------------------
for spec in 'ICON.PNG=64' 'ICON_256.PNG=256' 'app/ui/images/icon_64.png=64' 'app/ui/images/icon_256.png=256'
do
    icon=${spec%%=*}
    size=${spec#*=}
    path="$PROJECT/$icon"
    [ -f "$path" ] || fail "Icon is missing: $icon"
    PNG_AVAILABLE=yes
    assert_eq "$(png_dimensions "$path")" "${size}x${size}" "Icon dimensions are invalid: $icon"
    icon_bytes=$(stat -c '%s' "$path")
    [ "$icon_bytes" -le 1048576 ] || fail "Icon exceeds the fnOS size limit: $icon"
done

# --- component lock ----------------------------------------------------------
[ -f "$PROJECT/binary.lock.json" ] || fail 'binary.lock.json is missing.'
json_valid "$PROJECT/binary.lock.json" || fail 'binary.lock.json is not valid JSON.'
if [ -n "$JSON_TOOL" ]; then
    assert_eq "$(json_get "$PROJECT/binary.lock.json" 'data["schema_version"]')" '1' \
        'binary.lock.json schema_version must be 1.'
    assert_eq "$(json_get "$PROJECT/binary.lock.json" 'data["package_version"]')" '1.0.16' \
        'binary.lock.json package identity is invalid.'
    assert_eq "$(json_get "$PROJECT/binary.lock.json" 'data["package"]')" 'cpa-manager-plus' \
        'binary.lock.json package name is invalid.'
    component_count=$(json_get "$PROJECT/binary.lock.json" 'len(data["components"])')
    assert_eq "$component_count" '2' 'binary.lock.json must describe both bundled components.'
fi

python3 -B "$PROJECT/tests/binary-cache.test.py" || fail 'Binary cache regression failed.'
BINARY_ROOT="$REPO_ROOT/.tmp/cpa-manager-plus-binaries"
python3 -B "$PROJECT/scripts/prepare-binaries.py" --cache-dir "$BINARY_ROOT" --offline ||
    fail 'Prepare the locked binaries first with scripts/prepare-binaries.py.'
upstream_state='verified (binary.lock.json)'
plugin_state='not bundled'

# --- lifecycle smoke test ----------------------------------------------------
[ -f "$PROJECT/tests/lifecycle-smoke.sh" ] || fail 'Lifecycle smoke test is missing.'
if port_busy 8317 || port_busy 18317; then
    printf 'SKIP: lifecycle smoke test needs ports 8317 and 18317 to be free.\n' >&2
    printf '      Stop the local cpa-manager-plus instance and re-run.\n' >&2
    smoke_state='skipped (ports 8317/18317 busy)'
else
    sh "$PROJECT/tests/lifecycle-smoke.sh" || fail 'Lifecycle smoke test failed.'
    smoke_state='passed'
fi

# --- CLIProxyAPI v8 migration integration ------------------------------------
migration_test="$PROJECT/tests/config-v8-migration.sh"
[ -f "$migration_test" ] || fail 'CLIProxyAPI v8 migration test is missing.'
cli_version=$(json_get "$PROJECT/binary.lock.json" "next(c['version'] for c in data['components'] if c['name'] == 'cli-proxy-api')")
cli_test_binary="$BINARY_ROOT/cli-proxy-api/$cli_version/cli-proxy-api"
[ -x "$cli_test_binary" ] || fail 'The locked CLIProxyAPI binary is not executable.'
CLI_PROXY_API_BIN="$cli_test_binary" sh "$migration_test" ||
    fail 'CLIProxyAPI v8 migration test failed.'
migration_state='passed'

printf 'AppName=cpa-manager-plus\n'
printf 'Version=%s\n' "$(manifest_value version)"
printf 'UpstreamLock=%s\n' "$upstream_state"
printf "PluginSources=%s\n" "$plugin_state"
printf 'PngChecks=%s\n' "$PNG_AVAILABLE"
printf 'JsonChecks=%s\n' "${JSON_TOOL:-skipped}"
printf 'LifecycleSmoke=%s\n' "$smoke_state"
printf 'V8Migration=%s\n' "$migration_state"
printf 'Result=passed\n'
