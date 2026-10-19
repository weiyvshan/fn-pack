#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/deepseek-harness-pnpm-launcher.XXXXXXXX")
trap 'rm -rf -- "$temporary_root"' EXIT HUP INT TERM

fake_app="${temporary_root}/app"
fake_var="${temporary_root}/var"
fake_home="${temporary_root}/home"
fake_node="${temporary_root}/node"
fake_pnpm="${fake_app}/pnpm/bin/pnpm.cjs"
test_launcher="${temporary_root}/pnpm-launcher"
output_file="${temporary_root}/argv"
store_file="${temporary_root}/store"
path_node_file="${temporary_root}/path-node"
proxy_file="${temporary_root}/proxy-env"

mkdir -p "$(dirname -- "$fake_pnpm")" "${fake_home}/.dsh/profiles/web" "${fake_home}/.dsh/profiles/-custom"
: >"$fake_pnpm"
cat >"$fake_node" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >"${TEST_OUTPUT:?}"
printf '%s\n' "${pnpm_config_store_dir:?}" >"${TEST_STORE_OUTPUT:?}"
command -v node >"${TEST_PATH_NODE_OUTPUT:?}"
{
  printf 'HTTP_PROXY=%s\n' "${HTTP_PROXY-__unset__}"
  printf 'HTTPS_PROXY=%s\n' "${HTTPS_PROXY-__unset__}"
  printf 'http_proxy=%s\n' "${http_proxy-__unset__}"
  printf 'https_proxy=%s\n' "${https_proxy-__unset__}"
  printf 'NO_PROXY=%s\n' "${NO_PROXY-__unset__}"
  printf 'no_proxy=%s\n' "${no_proxy-__unset__}"
  printf 'npm_config_proxy=%s\n' "${npm_config_proxy-__unset__}"
  printf 'npm_config_https_proxy=%s\n' "${npm_config_https_proxy-__unset__}"
  printf 'npm_config_noproxy=%s\n' "${npm_config_noproxy-__unset__}"
} >"${TEST_PROXY_OUTPUT:?}"
EOF
chmod 0755 "$fake_node"

sed \
  -e "s|^NODE_BIN=.*$|NODE_BIN=${fake_node}|" \
  -e "s|^PNPM_ENTRY=.*$|PNPM_ENTRY=${fake_pnpm}|" \
  "${ROOT}/app/pnpm-launcher" >"$test_launcher"
chmod 0755 "$test_launcher"

run_launcher() {
  env -u DSH_PLUGIN_STORE_DIR \
    -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
    -u NO_PROXY -u no_proxy \
    -u npm_config_proxy -u npm_config_https_proxy -u npm_config_noproxy \
    TRIM_APPDEST="$fake_app" \
    TRIM_PKGVAR="$fake_var" \
    TRIM_PKGHOME="$fake_home" \
    TEST_OUTPUT="$output_file" \
    TEST_STORE_OUTPUT="$store_file" \
    TEST_PATH_NODE_OUTPUT="$path_node_file" \
    TEST_PROXY_OUTPUT="$proxy_file" \
    "$test_launcher" "$@"
}

run_proxy_launcher() {
  env -u DSH_PLUGIN_STORE_DIR \
    -u npm_config_proxy -u npm_config_https_proxy -u npm_config_noproxy \
    HTTP_PROXY='http://proxy.test:7897' \
    HTTPS_PROXY='http://proxy.test:7897' \
    http_proxy='http://proxy.test:7897' \
    https_proxy='http://proxy.test:7897' \
    NO_PROXY='127.0.0.1,localhost' \
    no_proxy='127.0.0.1,localhost' \
    TRIM_APPDEST="$fake_app" \
    TRIM_PKGVAR="$fake_var" \
    TRIM_PKGHOME="$fake_home" \
    TEST_OUTPUT="$output_file" \
    TEST_STORE_OUTPUT="$store_file" \
    TEST_PATH_NODE_OUTPUT="$path_node_file" \
    TEST_PROXY_OUTPUT="$proxy_file" \
    "$test_launcher" "$@"
}

run_plugin_launcher() {
  local store=$1
  shift
  env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
    -u NO_PROXY -u no_proxy \
    -u npm_config_proxy -u npm_config_https_proxy -u npm_config_noproxy \
    DSH_PLUGIN_STORE_DIR="$store" \
    TRIM_APPDEST="$fake_app" \
    TRIM_PKGVAR="$fake_var" \
    TRIM_PKGHOME="$fake_home" \
    TEST_OUTPUT="$output_file" \
    TEST_STORE_OUTPUT="$store_file" \
    TEST_PATH_NODE_OUTPUT="$path_node_file" \
    TEST_PROXY_OUTPUT="$proxy_file" \
    "$test_launcher" "$@"
}

assert_argv() {
  local expected_store=$1
  mapfile -t argv <"$output_file"
  [ "${argv[0]}" = "$fake_pnpm" ]
  [ "${argv[1]}" = '--version' ]
  [ "${#argv[@]}" -eq 2 ]
  [ "$(cat "$store_file")" = "$expected_store" ]
  [ "$(cat "$path_node_file")" = "$fake_node" ]
}

run_launcher --version
assert_argv "${fake_var}/pnpm-store"
grep -Fqx 'HTTP_PROXY=__unset__' "$proxy_file"
grep -Fqx 'HTTPS_PROXY=__unset__' "$proxy_file"
grep -Fqx 'http_proxy=__unset__' "$proxy_file"
grep -Fqx 'https_proxy=__unset__' "$proxy_file"
grep -Fqx 'NO_PROXY=__unset__' "$proxy_file"
grep -Fqx 'no_proxy=__unset__' "$proxy_file"
grep -Fqx 'npm_config_proxy=__unset__' "$proxy_file"
grep -Fqx 'npm_config_https_proxy=__unset__' "$proxy_file"
grep -Fqx 'npm_config_noproxy=__unset__' "$proxy_file"

run_proxy_launcher --version
assert_argv "${fake_var}/pnpm-store"
grep -Fqx 'HTTP_PROXY=http://proxy.test:7897' "$proxy_file"
grep -Fqx 'HTTPS_PROXY=http://proxy.test:7897' "$proxy_file"
grep -Fqx 'http_proxy=http://proxy.test:7897' "$proxy_file"
grep -Fqx 'https_proxy=http://proxy.test:7897' "$proxy_file"
grep -Fqx 'NO_PROXY=127.0.0.1,localhost' "$proxy_file"
grep -Fqx 'no_proxy=127.0.0.1,localhost' "$proxy_file"
grep -Fqx 'npm_config_proxy=http://proxy.test:7897' "$proxy_file"
grep -Fqx 'npm_config_https_proxy=http://proxy.test:7897' "$proxy_file"
grep -Fqx 'npm_config_noproxy=127.0.0.1,localhost' "$proxy_file"

profile_store="${fake_home}/.dsh/profiles/-custom/.pnpm-store"
run_plugin_launcher "$profile_store" --version
assert_argv "$profile_store"

expect_rejected() {
  local store=$1
  rm -f -- "$output_file"
  if run_plugin_launcher "$store" --version >/dev/null 2>&1; then
    printf 'expected launcher rejection for store: %q\n' "$store" >&2
    exit 1
  fi
  [ ! -e "$output_file" ] || {
    printf 'rejected store reached node: %q\n' "$store" >&2
    exit 1
  }
}

expect_rejected ''
expect_rejected "${fake_var}/pnpm-store"
expect_rejected "${fake_home}/.dsh/profiles/web/../other/.pnpm-store"
expect_rejected "${fake_home}/.dsh/profiles/web/nested/.pnpm-store"
expect_rejected "${fake_home}/.dsh/profiles/node_modules/.pnpm-store"
expect_rejected "${fake_home}/.dsh/profiles/web/.pnpm-store"$'\n'

case $(uname -s) in
  MINGW*|MSYS*|CYGWIN*) ;;
  *)
  ln -s -- web "${fake_home}/.dsh/profiles/linked"
  expect_rejected "${fake_home}/.dsh/profiles/linked/.pnpm-store"
  rm -- "${fake_home}/.dsh/profiles/linked"

  ln -s -- "${temporary_root}/outside-store" "${fake_home}/.dsh/profiles/web/.pnpm-store"
  expect_rejected "${fake_home}/.dsh/profiles/web/.pnpm-store"
  rm -- "${fake_home}/.dsh/profiles/web/.pnpm-store"
  ;;
esac

printf '%s\n' 'pnpm launcher tests passed'
