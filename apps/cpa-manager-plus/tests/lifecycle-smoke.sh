#!/bin/sh
# Lifecycle smoke test for the cpa-manager-plus fnOS package.
#
# Mirror of tests/lifecycle-smoke.ps1 for POSIX hosts (fnOS), plus a startup
# identity race regression: a service candidate that is still alive but has not
# finished execve must never be reported as an early exit, and the startup
# cleanup must not signal a candidate it cannot yet prove it owns.
set -u

PROJECT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=${TMPDIR:-/tmp}/cpa-manager-plus-lifecycle-$$
APP_DEST="$TEST_ROOT/target"
PKG_ETC="$TEST_ROOT/etc"
PKG_VAR="$TEST_ROOT/var"
PKG_TMP="$TEST_ROOT/tmp"
PKG_HOME="$TEST_ROOT/home"
LOG_PATH="$TEST_ROOT/temp.log"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    case "$TEST_ROOT" in
        "${TMPDIR:-/tmp}"/cpa-manager-plus-lifecycle-*) rm -rf -- "$TEST_ROOT" ;;
        *) printf 'Refusing to clean unexpected test root: %s\n' "$TEST_ROOT" >&2 ;;
    esac
}
trap cleanup EXIT HUP INT TERM

run_sh() {
    _script=$1
    _expected=$2
    shift 2
    sh "$_script" "$@"
    _rc=$?
    [ "$_rc" -eq "$_expected" ] ||
        fail "$(basename -- "$_script") $* returned $_rc, expected $_expected"
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

assert_eq() {
    [ "$1" = "$2" ] || fail "$3 (got [$1], want [$2])"
}

prepare_layout() {
    mkdir -p "$APP_DEST/defaults" "$APP_DEST/bin" \
        "$PKG_ETC" "$PKG_VAR" "$PKG_TMP" "$PKG_HOME"
    cp "$PROJECT/app/defaults/cli-proxy-api.yaml" "$APP_DEST/defaults/cli-proxy-api.yaml"
    printf 'test' > "$APP_DEST/bin/cli-proxy-api"
    printf 'test' > "$APP_DEST/bin/cpa-manager-plus"
    chmod 0755 "$APP_DEST/bin/cli-proxy-api" "$APP_DEST/bin/cpa-manager-plus"
}

export TRIM_APPNAME='cpa-manager-plus'
export TRIM_APPDEST="$APP_DEST"
export TRIM_PKGETC="$PKG_ETC"
export TRIM_PKGVAR="$PKG_VAR"
export TRIM_PKGTMP="$PKG_TMP"
export TRIM_PKGHOME="$PKG_HOME"
export TRIM_TEMP_LOGFILE="$LOG_PATH"
# Deliberately not the invoking uid: the ownership matcher must treat foreign
# package processes as unowned, so the smoke test can never signal them.
export TRIM_UID='4242'
export wizard_cpamp_admin_key='AdminKey-For-Test-1234'
export wizard_cli_api_key='ClientKey-For-Test-123'

prepare_layout

CONFIG_PATH="$PKG_ETC/cli-proxy-api/config.yaml"
ADMIN_PATH="$PKG_ETC/secrets/cpamp-admin-key"
MANAGEMENT_PATH="$PKG_ETC/secrets/cpa-management-key"
INSTALLED_PLUGIN="$PKG_VAR/cli-proxy-api/plugins/credential-time-policy.so"
RUN_DIR="$PKG_VAR/cpa-manager-plus/run"
MAIN_SCRIPT="$PROJECT/cmd/main"

# --- Fresh install -----------------------------------------------------------
run_sh "$PROJECT/cmd/install_callback" 0
[ -f "$CONFIG_PATH" ] || fail 'Fresh install did not create the CLIProxyAPI config.'
config=$(cat "$CONFIG_PATH")
assert_not_contains "$config" '__' 'Fresh install left an unresolved config placeholder.'
assert_contains "$config" 'ClientKey-For-Test-123' 'Fresh install did not persist the client API key.'
assert_contains "$config" 'allow-remote: true' 'Fresh install did not enable the management access required by the CPAMP reverse proxy.'
grep -Eq '^config-version:[[:space:]]*8[[:space:]]*$' "$CONFIG_PATH" || fail 'Fresh install did not write config-version 8.'
grep -Eq '^server:[[:space:]]*$' "$CONFIG_PATH" || fail 'Fresh install has no v8 server section.'
grep -Eq '^management:[[:space:]]*$' "$CONFIG_PATH" || fail 'Fresh install has no v8 management section.'
grep -Eq '^access:[[:space:]]*$' "$CONFIG_PATH" || fail 'Fresh install has no v8 access section.'
grep -Eq '^  api-keys:[[:space:]]*$' "$CONFIG_PATH" || fail 'Fresh install did not nest client API keys under access.'
grep -Eq '^oauth:[[:space:]]*$' "$CONFIG_PATH" || fail 'Fresh install has no v8 oauth section.'
grep -Eq '^observability:[[:space:]]*$' "$CONFIG_PATH" || fail 'Fresh install has no v8 observability section.'
if grep -Eq '^(host|port|remote-management|api-keys|auth-dir|debug|logging-to-file|usage-statistics-enabled|request-retry):' "$CONFIG_PATH"; then
    fail 'Fresh install retained a legacy top-level CLIProxyAPI field.'
fi
assert_eq "$(cat "$ADMIN_PATH")" 'AdminKey-For-Test-1234' 'Fresh install admin key differs from the wizard value.'
management_key=$(cat "$MANAGEMENT_PATH")
case "$management_key" in
    [A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9]) : ;;
    *) fail 'Fresh install did not generate a 48-character management key.' ;;
esac
assert_contains "$config" "$management_key" 'Generated management key does not match the CLIProxyAPI config.'
# The package no longer ships the credential time policy plugin, and no config
# stanza may keep referencing it.
[ ! -e "$INSTALLED_PLUGIN" ] || fail 'Fresh install deployed a bundled plugin that the package no longer carries.'
assert_not_contains "$config" 'credential-time-policy' 'Default config still references the removed credential time policy plugin.'

# --- Repeated install preserves secrets --------------------------------------
export wizard_cpamp_admin_key='Replacement-Admin-Key-1234'
export wizard_cli_api_key='Replacement-Client-Key-123'
run_sh "$PROJECT/cmd/install_callback" 0
assert_eq "$(cat "$ADMIN_PATH")" 'AdminKey-For-Test-1234' 'Repeated install overwrote the preserved admin key.'
assert_eq "$(cat "$MANAGEMENT_PATH")" "$management_key" 'Repeated install overwrote the internal management key.'
assert_eq "$(cat "$CONFIG_PATH")" "$config" 'Repeated install overwrote the preserved CLIProxyAPI config.'

# --- Upgrade from a genuine legacy config ------------------------------------
cat > "$CONFIG_PATH" <<EOF
host: "0.0.0.0"
port: 8317
remote-management:
  allow-remote: false
  secret-key: "$management_key"
  disable-control-panel: true
  disable-auto-update-panel: true
api-keys:
  - "ClientKey-For-Test-123"
auth-dir: "$PKG_VAR/cli-proxy-api/auths"
debug: false
logging-to-file: false
usage-statistics-enabled: true
redis-usage-queue-retention-seconds: 3600
request-retry: 3
plugins:
  enabled: true
  dir: "$PKG_VAR/cli-proxy-api/plugins"
custom-marker: "preserve-me"
EOF
legacy_expected="$TEST_ROOT/legacy-expected.yaml"
sed 's/allow-remote: false/allow-remote: true/' "$CONFIG_PATH" > "$legacy_expected"
printf '{"type":"codex","access_token":"fixture"}' > "$PKG_VAR/cli-proxy-api/auths/fixture.json"
printf 'user-plugin' > "$PKG_VAR/cli-proxy-api/plugins/user-plugin.so"
printf 'usage-db' > "$PKG_VAR/cpa-manager-plus/usage.sqlite"
printf 'data-key' > "$PKG_VAR/cpa-manager-plus/data.key"
run_sh "$PROJECT/cmd/upgrade_init" 0
run_sh "$PROJECT/cmd/upgrade_callback" 0
upgraded_config=$(cat "$CONFIG_PATH")
cmp -s "$CONFIG_PATH" "$legacy_expected" || fail 'Upgrade changed legacy config beyond the required allow-remote boolean.'
assert_contains "$upgraded_config" 'remote-management:' 'Upgrade migrated the legacy management section eagerly.'
assert_not_contains "$upgraded_config" 'config-version: 8' 'Upgrade added config-version 8 before a v8 management write.'
assert_contains "$upgraded_config" 'allow-remote: true' 'Upgrade did not enable the management access required by the CPAMP reverse proxy.'
assert_contains "$upgraded_config" 'ClientKey-For-Test-123' 'Upgrade lost the preserved CLIProxyAPI client API key.'
assert_contains "$upgraded_config" 'custom-marker: "preserve-me"' 'Upgrade lost an unrelated user config field.'
assert_eq "$(cat "$ADMIN_PATH")" 'AdminKey-For-Test-1234' 'Upgrade changed the preserved CPAMP administrator key.'
assert_eq "$(cat "$MANAGEMENT_PATH")" "$management_key" 'Upgrade changed the preserved CPA management key.'
assert_eq "$(cat "$PKG_VAR/cli-proxy-api/auths/fixture.json")" '{"type":"codex","access_token":"fixture"}' 'Upgrade changed a preserved OAuth credential.'
assert_eq "$(cat "$PKG_VAR/cpa-manager-plus/usage.sqlite")" 'usage-db' 'Upgrade changed the preserved usage database.'
assert_eq "$(cat "$PKG_VAR/cpa-manager-plus/data.key")" 'data-key' 'Upgrade changed the preserved encryption key.'
[ ! -e "$INSTALLED_PLUGIN" ] || fail 'Upgrade introduced a bundled plugin that the package no longer carries.'
assert_eq "$(cat "$PKG_VAR/cli-proxy-api/plugins/user-plugin.so")" 'user-plugin' 'Upgrade changed an unrelated user plugin.'

# --- Status contract ---------------------------------------------------------
run_sh "$MAIN_SCRIPT" 3 status
[ ! -e "$RUN_DIR/lifecycle.lock" ] || fail 'Status did not release the lifecycle lock.'
assert_contains "$(cat "$LOG_PATH")" 'stopped' 'Stopped status did not write an actionable result.'
printf '999999' > "$RUN_DIR/cli-proxy-api.pid"
run_sh "$MAIN_SCRIPT" 1 status
assert_contains "$(cat "$LOG_PATH")" 'PID' 'Partial status did not report the PID/health failure.'
run_sh "$MAIN_SCRIPT" 1 unknown-action

# --- Startup identity race regression ----------------------------------------
# A candidate that is alive but has not finished execve reports an exe that is
# not the target binary yet. The old logic declared an early exit and then
# stopped the already healthy peer service; the fixed logic waits, reports an
# identity timeout, and leaves the unowned candidate alone.
startup_identity_race() {
    race_lib="$TEST_ROOT/main-lib.sh"
    awk '/^case \$\{1:-} in$/{exit} {print}' "$MAIN_SCRIPT" > "$race_lib"
    grep -q 'identity_waited' "$race_lib" ||
        fail 'wait_for_service has no identity retry: the startup race fix is missing.'
    grep -q 'stop_verified_pid_waiting' "$race_lib" ||
        fail 'cleanup_startup has no ownership retry: the startup race fix is missing.'

    printf '#!/bin/sh\nsleep 20\n' > "$APP_DEST/bin/cli-proxy-api"
    chmod 0755 "$APP_DEST/bin/cli-proxy-api"
    : > "$LOG_PATH"

    # Run in a child shell: the library enables `set -eu` on source, which must
    # not terminate the smoke test itself.
    race_report=$(sh -c '
        set -u
        . "$1"
        set +e
        export TRIM_UID="$(id -u)"
        ( exec nohup "$CLI_BIN" -config "$CLI_CONFIG" >>"$CLI_LOG" 2>&1 ) &
        pid=$!
        sleep 1
        if ! kill -0 "$pid" 2>/dev/null; then
            printf "stub-did-not-survive"
            exit 0
        fi
        wait_for_service "$pid" "$CLI_BIN" "http://127.0.0.1:8317/healthz" CLIProxyAPI 14
        rc=$?
        stop_verified_pid_waiting "$pid" "$CLI_BIN" "CLIProxyAPI candidate" pid_matches
        alive=no
        kill -0 "$pid" 2>/dev/null && alive=yes
        kill "$pid" 2>/dev/null
        printf "rc=%s alive=%s\n" "$rc" "$alive"
    ' sh "$race_lib")

    race_message=$(cat "$LOG_PATH" 2>/dev/null || true)
    assert_not_contains "$race_message" '启动后提前退出' \
        'A live but not yet identified candidate was reported as an early exit.'
    assert_contains "$race_message" '无法确认' \
        'A live but unidentified candidate did not report the identity timeout.'
    assert_contains "$race_report" 'rc=1' 'Starting with an unidentifiable candidate must fail.'
    assert_contains "$race_report" 'alive=yes' \
        'Startup cleanup signalled a candidate it could not prove ownership of.'

    printf 'test' > "$APP_DEST/bin/cli-proxy-api"
    chmod 0755 "$APP_DEST/bin/cli-proxy-api"
}
startup_identity_race

# --- Executable evidence fallback --------------------------------------------
# App Center runs the lifecycle hooks as the package user without capabilities,
# and the kernel then denies readlink on /proc/<pid>/exe for a process that is
# neither an ancestor nor privileged, while /proc/<pid>/cmdline and
# /proc/<pid>/comm stay readable. The identity check must keep recognising the
# package process in that context instead of declaring it unowned, which is what
# left a live CLIProxyAPI holding port 8317 during stop and upgrade.
executable_evidence_fallback() {
    fake_bin="$TEST_ROOT/fakebin"
    mkdir -p "$fake_bin"
    cat > "$fake_bin/readlink" <<'STUB'
#!/bin/sh
case ${1:-} in
    /proc/*/exe) exit 1 ;;
esac
exec /usr/bin/readlink "$@"
STUB
    chmod 0755 "$fake_bin/readlink"

    evidence_lib="$TEST_ROOT/evidence-lib.sh"
    awk '/^case \$\{1:-} in$/{exit} {print}' "$MAIN_SCRIPT" > "$evidence_lib"
    grep -q 'package_process_binary' "$evidence_lib" ||
        fail 'The executable evidence fallback is missing from the lifecycle script.'
    if grep -q 'process_exe=$(readlink "/proc/$pid/exe" 2>/dev/null) || return 1' "$evidence_lib"; then
        fail 'The lifecycle script still treats an unreadable /proc/<pid>/exe as unowned.'
    fi

    # An ELF process whose argv[0] is the packaged binary path, matching what the
    # supervisor records for a real service. A shell stub would rewrite argv[0] to
    # the interpreter and could not represent a packaged binary.
    cp /bin/sleep "$APP_DEST/bin/cpa-manager-plus"
    chmod 0755 "$APP_DEST/bin/cpa-manager-plus"

    evidence_report=$(sh -c '
        set -u
        PATH="$1:$PATH"
        export PATH
        . "$2"
        set +e
        export TRIM_UID="$(id -u)"
        "$CPA_BIN" 20 &
        pid=$!
        sleep 1
        matched=no
        if pid_matches_package_binary "$pid" "$CPA_BIN"; then matched=yes; fi
        source_used=exe
        if [ -z "$(readlink "/proc/$pid/exe" 2>/dev/null)" ]; then source_used=fallback; fi
        kill "$pid" 2>/dev/null
        printf "matched=%s source=%s\n" "$matched" "$source_used"
    ' sh "$fake_bin" "$evidence_lib")

    assert_contains "$evidence_report" 'matched=yes' \
        'A package process stayed unrecognised while /proc/<pid>/exe was unreadable.'
    assert_contains "$evidence_report" 'source=fallback' \
        'The executable evidence fallback was not exercised by this regression.'

    printf 'test' > "$APP_DEST/bin/cpa-manager-plus"
    chmod 0755 "$APP_DEST/bin/cpa-manager-plus"
}
executable_evidence_fallback

# --- Uninstall contract ------------------------------------------------------
export delete_data='false'
run_sh "$PROJECT/cmd/uninstall_callback" 0
[ -d "$PKG_ETC" ] && [ -d "$PKG_VAR" ] && [ -d "$PKG_HOME" ] ||
    fail 'Default uninstall did not preserve application data.'
export delete_data='true'
run_sh "$PROJECT/cmd/uninstall_callback" 0
[ ! -e "$PKG_ETC" ] && [ ! -e "$PKG_VAR" ] && [ ! -e "$PKG_HOME" ] ||
    fail 'Explicit uninstall did not delete the three application-owned roots.'

printf 'FreshInstall=passed\n'
printf 'PreservedReinstall=passed\n'
printf 'LegacyConfigUpgrade=passed\n'
printf 'PluginNotBundled=passed\n'
printf 'StatusContract=passed\n'
printf 'StartupIdentityRace=passed\n'
printf 'ExecutableEvidenceFallback=passed\n'
printf 'UninstallContract=passed\n'
