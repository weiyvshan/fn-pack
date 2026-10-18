#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/deepseek-harness-dsh-launcher.XXXXXXXX")
trap 'rm -rf -- "$temporary_root"' EXIT HUP INT TERM

# 本机在 fnOS 应用环境内运行时，环境已带 TRIM_PKGHOME；launcher 会优先取它
# （PKG_HOME=${TRIM_PKGHOME:-...}），夹具算出的 PKG_HOME 被覆盖导致断言误判。
unset TRIM_PKGHOME

fake_app="${temporary_root}/app"
fake_var="${temporary_root}/var"
fake_node="${temporary_root}/node-runtime/bin/node"
fake_entry="${fake_app}/server/node_modules/@deepseek-ai/dsh/lib/bin.js"
fake_maintenance_skill="${fake_app}/builtin-skills/dsh-maintenance/SKILL.md"
fake_skill_creator="${fake_app}/builtin-skills/skill-creator/SKILL.md"
test_launcher="${fake_var}/bin/dsh"
output_file="${temporary_root}/output"
error_file="${temporary_root}/error"

mkdir -p "$(dirname -- "$fake_node")" "$(dirname -- "$fake_entry")" "$(dirname -- "$fake_maintenance_skill")" "$(dirname -- "$fake_skill_creator")" "$(dirname -- "$test_launcher")"
: >"$fake_entry"
: >"$fake_maintenance_skill"
: >"$fake_skill_creator"
cat >"$fake_node" <<'EOF'
#!/bin/sh
{
  printf 'TRIM_APPDEST=%s\n' "${TRIM_APPDEST:?}"
  printf 'TRIM_PKGVAR=%s\n' "${TRIM_PKGVAR:?}"
  printf 'TRIM_PKGHOME=%s\n' "${TRIM_PKGHOME:?}"
  printf 'DSH_HOME=%s\n' "${DSH_HOME:?}"
  printf 'DSH_BUNDLED_SKILL_DIR=%s\n' "${DSH_BUNDLED_SKILL_DIR:?}"
  if [ "${DSH_ADDITIONAL_WRITABLE_ROOTS+x}" = x ]; then
    printf 'DSH_ADDITIONAL_WRITABLE_ROOTS=%s\n' "$DSH_ADDITIONAL_WRITABLE_ROOTS"
  else
    printf '%s\n' 'DSH_ADDITIONAL_WRITABLE_ROOTS=unset'
  fi
  if [ "${DSH_PERMISSION_MODE+x}" = x ]; then
    printf 'DSH_PERMISSION_MODE=%s\n' "$DSH_PERMISSION_MODE"
  else
    printf '%s\n' 'DSH_PERMISSION_MODE=unset'
  fi
  printf 'DSH_FNOS_PLUGIN_POLICY=%s\n' "${DSH_FNOS_PLUGIN_POLICY:?}"
  printf 'PATH=%s\n' "$PATH"
  printf 'ARGV=%s\n' "$*"
} >"${TEST_OUTPUT:?}"
EOF
chmod 0755 "$fake_node"

sed \
  -e "s|^APP_DEST=.*$|APP_DEST=${fake_app}|" \
  -e "s|^NODE_BIN=.*$|NODE_BIN=${fake_node}|" \
  "${ROOT}/app/dsh-launcher" >"$test_launcher"
chmod 0700 "$test_launcher"

TRIM_APPDEST=/poison/app \
TRIM_PKGVAR=/poison/var \
DSH_HOME=/poison/home \
DSH_BUNDLED_SKILL_DIR=/poison/bundled-skills \
DSH_ADDITIONAL_WRITABLE_ROOTS=/poison/additional-root \
DSH_PERMISSION_MODE=danger-full-access \
PATH=/poison/bin \
TEST_OUTPUT="$output_file" \
  "$test_launcher" plugin --profile web list

grep -Fx "TRIM_APPDEST=${fake_app}" "$output_file"
grep -Fx "TRIM_PKGVAR=${fake_var}" "$output_file"
grep -Fx "TRIM_PKGHOME=${temporary_root}/home" "$output_file"
grep -Fx "DSH_HOME=${temporary_root}/home/.dsh" "$output_file"
grep -Fx "DSH_BUNDLED_SKILL_DIR=${fake_app}/builtin-skills" "$output_file"
grep -Fx 'DSH_ADDITIONAL_WRITABLE_ROOTS=unset' "$output_file"
grep -Fx 'DSH_PERMISSION_MODE=unset' "$output_file"
grep -Fx 'DSH_FNOS_PLUGIN_POLICY=1' "$output_file"
grep -Fx "PATH=${fake_var}/bin:${temporary_root}/node-runtime/bin:/usr/local/bin:/usr/bin:/bin" "$output_file"
grep -Fx "ARGV=${fake_entry} plugin --profile web list" "$output_file"

rm -f -- "$fake_skill_creator"
set +e
TEST_OUTPUT="$output_file" "$test_launcher" plugin list 2>"$error_file"
missing_creator_status=$?
set -e
[ "$missing_creator_status" -ne 0 ]
grep -F "skill-creator/SKILL.md" "$error_file"

: >"$fake_skill_creator"
rm -f -- "$fake_maintenance_skill"
set +e
TEST_OUTPUT="$output_file" "$test_launcher" plugin list 2>"$error_file"
missing_maintenance_status=$?
set -e
[ "$missing_maintenance_status" -ne 0 ]
grep -F "dsh-maintenance/SKILL.md" "$error_file"

printf '%s\n' 'dsh launcher tests passed'
