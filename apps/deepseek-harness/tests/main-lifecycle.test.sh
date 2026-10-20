#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MAIN_SCRIPT="${SCRIPT_DIR}/../cmd/main"
INSTALL_CALLBACK="${SCRIPT_DIR}/../cmd/install_callback"
CONFIG_CALLBACK="${SCRIPT_DIR}/../cmd/config_callback"
FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/deepseek-harness-main-test.XXXXXX")
trap 'rm -rf -- "$FIXTURE"' EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

grep -Fq 'BUNDLED_SKILL_DIR="${TRIM_APPDEST}/builtin-skills"' "$MAIN_SCRIPT" ||
  fail 'App Center startup does not use the packaged bundled skill root'
grep -Fq 'BUNDLED_MAINTENANCE_SKILL="${BUNDLED_SKILL_DIR}/dsh-maintenance/SKILL.md"' "$MAIN_SCRIPT" ||
  fail 'App Center startup does not require dsh-maintenance'
grep -Fq 'BUNDLED_SKILL_CREATOR="${BUNDLED_SKILL_DIR}/skill-creator/SKILL.md"' "$MAIN_SCRIPT" ||
  fail 'App Center startup does not require skill-creator'
grep -Fq 'export DSH_BUNDLED_SKILL_DIR="$BUNDLED_SKILL_DIR"' "$MAIN_SCRIPT" ||
  fail 'App Center startup does not export the bundled skill root'
if grep -Fq 'gateway-route-injection/SKILL.md' "$MAIN_SCRIPT"; then
  fail 'App Center startup still requires the retired bundled skill'
fi

for lifecycle_script in \
  "$MAIN_SCRIPT" \
  "${SCRIPT_DIR}/../cmd/config-common" \
  "${SCRIPT_DIR}/../cmd/install_callback" \
  "${SCRIPT_DIR}/../cmd/upgrade_init" \
  "${SCRIPT_DIR}/../cmd/upgrade_callback" \
  "${SCRIPT_DIR}/../cmd/uninstall_init" \
  "${SCRIPT_DIR}/../cmd/uninstall_callback"
do
  if grep -Eq 'TRIM_PKGVAR.*bundled-skills|DSH_HOME.*skills/(dsh-maintenance|skill-creator)|setfacl.*skills|chown.*skills' "$lifecycle_script"; then
    fail "lifecycle code synchronizes persistent skills or manages user-skill ACLs: $lifecycle_script"
  fi
done

current_uid=$(id -u)
if [ "$current_uid" -eq 0 ]; then
  wrong_uid=1
else
  wrong_uid=0
fi

# The startup stability window must tell a dead backend apart from a busy one.
# The readiness probe answers within a short timeout, so a backend that is
# still finishing its startup work can miss it without being gone, and the
# lifecycle script must not destroy such a backend.
. "${SCRIPT_DIR}/../cmd/config-common"

[ "$(backend_stability_state no yes 0 5)" = 'exited' ] ||
  fail 'a missing backend process is not reported as exited'
[ "$(backend_stability_state yes yes 0 5)" = 'ready' ] ||
  fail 'a responsive backend is not reported as ready'
[ "$(backend_stability_state yes no 1 5)" = 'slow' ] ||
  fail 'a busy backend is not reported as slow'
[ "$(backend_stability_state yes no 5 5)" = 'unresponsive' ] ||
  fail 'a backend that keeps missing the probe is not reported as unresponsive'

if should_stop_backend_after_failed_start yes yes; then
  fail 'a healthy backend is stopped after a failed start'
fi
if ! should_stop_backend_after_failed_start yes no; then
  fail 'an unresponsive backend is kept after a failed start'
fi
if ! should_stop_backend_after_failed_start no no; then
  fail 'a dead backend is kept after a failed start'
fi

grep -Fq 'backend_stability_state' "$MAIN_SCRIPT" ||
  fail 'App Center startup does not classify the backend state during the stability window'
grep -Fq 'should_stop_backend_after_failed_start' "$MAIN_SCRIPT" ||
  fail 'App Center startup does not keep a healthy backend after a failed start'
grep -Fq 'Kept the healthy DeepSeek Harness backend running after an incomplete startup.' "$MAIN_SCRIPT" ||
  fail 'App Center startup does not report the kept backend'
grep -Fq 'Reusing the healthy DeepSeek Harness backend while repairing the partial service state.' "$MAIN_SCRIPT" ||
  fail 'App Center startup does not reuse a healthy backend'
grep -Fq 'completing the startup' "$MAIN_SCRIPT" ||
  fail 'App Center startup does not complete an interrupted startup'
if grep -Fq '! owned_process_running "$PID_FILE" "$DSH_ENTRY" ||' "$MAIN_SCRIPT"; then
  fail 'App Center startup still treats a failed probe as a dead backend'
fi

# A busy backend must stay a recoverable condition: the slow branch may only
# record the miss, it must never end the startup.
slow_branch=$(sed -n '/^      slow)/,/^        ;;/p' "$MAIN_SCRIPT")
[ -n "$slow_branch" ] || fail 'App Center startup has no slow backend branch'
if printf '%s\n' "$slow_branch" | grep -Eq 'report_error|return 1|exit 1'; then
  fail 'App Center startup still fails the startup for a busy backend'
fi
stability_window=$(sed -n '/^wait_for_backend_stability() {/,/^}/p' "$MAIN_SCRIPT")
[ -n "$stability_window" ] || fail 'App Center startup has no stability window'
if ! printf '%s\n' "$stability_window" | grep -Fq 'consecutive_misses=$((consecutive_misses + 1))'; then
  fail 'App Center startup does not count a missed probe as a slow backend'
fi
if ! printf '%s\n' "$stability_window" | grep -Fq 'consecutive_misses=0'; then
  fail 'App Center startup does not reset the slow backend counter'
fi

set +e
output=$(
  TRIM_APPDEST="${FIXTURE}/app" \
  TRIM_PKGVAR="${FIXTURE}/var" \
  TRIM_PKGHOME="${FIXTURE}/volume/@apphome/deepseek-harness" \
  TRIM_TEMP_LOGFILE="${FIXTURE}/error.log" \
  TRIM_UID="$wrong_uid" \
  "$MAIN_SCRIPT" start 2>&1
)
status=$?
set -e

[ "$status" -ne 0 ] || fail 'start unexpectedly accepted the wrong UID'
printf '%s\n' "$output" | grep -Fq '请通过 fnOS 应用中心启用' || fail 'wrong-UID error is not actionable'

for path in \
  "${FIXTURE}/var/backend.port" \
  "${FIXTURE}/var/dsh.pid" \
  "${FIXTURE}/var/proxy.pid" \
  "${FIXTURE}/var/web-auth.token" \
  "${FIXTURE}/var/dsh.log" \
  "${FIXTURE}/error.log"
do
  [ ! -e "$path" ] || fail "wrong-UID start wrote persistent state: $path"
done

setup_config_fixture() {
  fixture_root=$1
  app_dest="${fixture_root}/volume/@appcenter/deepseek-harness"
  package_var="${fixture_root}/volume/@appdata/deepseek-harness"
  package_home="${fixture_root}/volume/@apphome/deepseek-harness"
  workspace="${fixture_root}/workspace"
  mkdir -p \
    "${app_dest}/pnpm/bin" \
    "${app_dest}/server/node_modules/@deepseek-ai/dsh/lib" \
    "${app_dest}/server/node_modules/@deepseek-ai/node-addon-system-linux-x64/bin" \
    "$package_var" "$package_home" "$workspace"
  cp -- "${SCRIPT_DIR}/../app/pnpm-launcher" "${app_dest}/pnpm-launcher"
  cp -- "${SCRIPT_DIR}/../app/dsh-launcher" "${app_dest}/dsh-launcher"
  : >"${app_dest}/pnpm/bin/pnpm.cjs"
  : >"${app_dest}/server/node_modules/@deepseek-ai/dsh/lib/bin.js"
  printf '#!/bin/sh\nexit 0\n' >"${app_dest}/server/node_modules/@deepseek-ai/node-addon-system-linux-x64/bin/landlock-run"
}

run_install_callback() {
  fixture_root=$1
  app_status=$2
  wizard_host=$3
  wizard_port=$4
  wizard_key=$5
  TRIM_APPDEST="${fixture_root}/volume/@appcenter/deepseek-harness" \
  TRIM_PKGVAR="${fixture_root}/volume/@appdata/deepseek-harness" \
  TRIM_PKGHOME="${fixture_root}/volume/@apphome/deepseek-harness" \
  TRIM_DATA_SHARE_PATHS="${fixture_root}/workspace" \
  TRIM_TEMP_LOGFILE="${fixture_root}/lifecycle-error.log" \
  TRIM_APP_STATUS="$app_status" \
  wizard_proxy_host="$wizard_host" \
  wizard_proxy_port="$wizard_port" \
  wizard_deepseek_api_key="$wizard_key" \
    "$INSTALL_CALLBACK" >/dev/null
}

run_config_callback() {
  fixture_root=$1
  config_host=$2
  config_port=$3
  config_key=$4
  clear_proxy=$5
  clear_api=$6
  TRIM_APPDEST="${fixture_root}/volume/@appcenter/deepseek-harness" \
  TRIM_PKGVAR="${fixture_root}/volume/@appdata/deepseek-harness" \
  TRIM_PKGHOME="${fixture_root}/volume/@apphome/deepseek-harness" \
  TRIM_TEMP_LOGFILE="${fixture_root}/lifecycle-error.log" \
  config_proxy_host="$config_host" \
  config_proxy_port="$config_port" \
  config_deepseek_api_key="$config_key" \
  config_clear_proxy="$clear_proxy" \
  config_clear_api_key="$clear_api" \
    "$CONFIG_CALLBACK" >/dev/null
}

fresh_fixture="${FIXTURE}/fresh"
setup_config_fixture "$fresh_fixture"
fresh_home="${fresh_fixture}/volume/@apphome/deepseek-harness/.dsh"
run_install_callback "$fresh_fixture" INSTALL initial.proxy.test 7890 sk-initial123
[ "$(cat "${fresh_home}/proxy.url")" = 'http://initial.proxy.test:7890' ] ||
  fail 'fresh install did not persist the initial proxy'
[ "$(cat "${fresh_home}/.env")" = 'DEEPSEEK_API_KEY=sk-initial123' ] ||
  fail 'fresh install did not persist the initial API key'
[ "$(cat "${fresh_home}/.fnos-wizard-config-initialized")" = 'initialized-v1' ] ||
  fail 'fresh install did not record wizard initialization'

run_config_callback "$fresh_fixture" configured.proxy.test 7891 sk-configured123 false false
run_install_callback "$fresh_fixture" UPGRADE stale.proxy.test 7999 sk-stale123
[ "$(cat "${fresh_home}/proxy.url")" = 'http://configured.proxy.test:7891' ] ||
  fail 'upgrade replayed the stale install-time proxy'
[ "$(cat "${fresh_home}/.env")" = 'DEEPSEEK_API_KEY=sk-configured123' ] ||
  fail 'upgrade replayed the stale install-time API key'

run_config_callback "$fresh_fixture" '' '' '' true true
[ ! -e "${fresh_home}/proxy.url" ] || fail 'configuration did not clear the proxy'
[ ! -e "${fresh_home}/.env" ] || fail 'configuration did not clear the API key'
run_install_callback "$fresh_fixture" UPGRADE stale.proxy.test 7999 sk-stale123
[ ! -e "${fresh_home}/proxy.url" ] || fail 'upgrade revived a cleared proxy'
[ ! -e "${fresh_home}/.env" ] || fail 'upgrade revived a cleared API key'
run_install_callback "$fresh_fixture" INSTALL stale.proxy.test 7999 sk-stale123
[ ! -e "${fresh_home}/proxy.url" ] || fail 'preserved reinstall revived a cleared proxy'
[ ! -e "${fresh_home}/.env" ] || fail 'preserved reinstall revived a cleared API key'

existing_fixture="${FIXTURE}/existing"
setup_config_fixture "$existing_fixture"
existing_home="${existing_fixture}/volume/@apphome/deepseek-harness/.dsh"
mkdir -p "$existing_home"
printf '%s\n' 'http://configured.proxy.test:7891' >"${existing_home}/proxy.url"
printf '%s\n' 'DEEPSEEK_API_KEY=sk-configured123' >"${existing_home}/.env"
run_install_callback "$existing_fixture" UPGRADE stale.proxy.test 7999 sk-stale123
[ "$(cat "${existing_home}/proxy.url")" = 'http://configured.proxy.test:7891' ] ||
  fail 'first fixed upgrade changed an existing proxy without a marker'
[ "$(cat "${existing_home}/.env")" = 'DEEPSEEK_API_KEY=sk-configured123' ] ||
  fail 'first fixed upgrade changed an existing API key without a marker'
[ "$(cat "${existing_home}/.fnos-wizard-config-initialized")" = 'initialized-v1' ] ||
  fail 'first fixed upgrade did not close wizard initialization'
run_install_callback "$existing_fixture" INSTALL stale.proxy.test 7999 sk-stale123
[ "$(cat "${existing_home}/proxy.url")" = 'http://configured.proxy.test:7891' ] ||
  fail 'preserved reinstall changed an existing proxy without a marker before callback'
[ "$(cat "${existing_home}/.env")" = 'DEEPSEEK_API_KEY=sk-configured123' ] ||
  fail 'preserved reinstall changed an existing API key without a marker before callback'

printf '%s\n' 'main lifecycle identity tests passed'
