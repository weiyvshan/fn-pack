#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 9 ] || [ $((($# - 6) % 3)) -ne 0 ]; then
  printf '%s\n' 'usage: build-source-runtime.sh <source.tar> <pnpm.tgz> <landlock.tgz> <runtime.tgz> <source-commit> <dsh-version> (<source.patch> <patch-sha256> <test-target>)...' >&2
  exit 2
fi

source_archive=$1
pnpm_archive=$2
landlock_archive=$3
runtime_archive=$4
source_commit=$5
expected_dsh_version=$6
shift 6
source_patches=()
expected_patch_sha256s=()
patch_test_targets=()
while [ "$#" -gt 0 ]; do
  source_patches+=("$1")
  expected_patch_sha256s+=("$2")
  patch_test_targets+=("$3")
  shift 3
done
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# The work root defaults to /tmp. Point DSH_BUILD_WORK_ROOT at the same
# filesystem as the pnpm store so installs link instead of copying 4+ GB.
work_root=$(mktemp -d "${DSH_BUILD_WORK_ROOT:-/tmp}/deepseek-harness-fnos.XXXXXXXX")
trap 'rm -rf -- "$work_root"' EXIT HUP INT TERM

case $(uname -m) in
  x86_64) ;;
  *) printf 'Linux x86-64 build host required, got %s\n' "$(uname -m)" >&2; exit 1 ;;
esac

case "$source_commit" in
  *[!0-9a-f]*|'') printf 'Invalid locked source commit: %s\n' "$source_commit" >&2; exit 1 ;;
esac
[ "${#source_commit}" -eq 40 ] || {
  printf 'Locked source commit must contain 40 lowercase hexadecimal characters: %s\n' "$source_commit" >&2
  exit 1
}

node_meets_requirement() {
  local candidate=$1
  local candidate_version candidate_major candidate_tail candidate_minor
  candidate_version=$("$candidate" -p 'process.versions.node' 2>/dev/null) || return 1
  candidate_major=${candidate_version%%.*}
  candidate_tail=${candidate_version#*.}
  candidate_minor=${candidate_tail%%.*}
  [ "$candidate_major" -gt 22 ] || { [ "$candidate_major" -eq 22 ] && [ "$candidate_minor" -ge 19 ]; }
}

select_node_runtime() {
  local node_path
  if command -v node >/dev/null 2>&1; then
    node_path=$(command -v node)
    if node_meets_requirement "$node_path"; then
      return 0
    fi
  fi
  while IFS= read -r node_path; do
    [ -x "$node_path" ] || continue
    if node_meets_requirement "$node_path"; then
      export PATH="$(dirname -- "$node_path"):$PATH"
      return 0
    fi
  done < <(find /root/.nvm/versions/node -path '*/bin/node' -type f 2>/dev/null | sort -Vr)
  return 1
}

check_elf_x86_64() {
  local file="$1"
  if [ ! -f "$file" ]; then
    return 1
  fi
  local header=""
  if command -v xxd >/dev/null 2>&1; then
    header=$(xxd -l 20 -ps "$file" 2>/dev/null) || true
  fi
  if [ -z "$header" ] && command -v od >/dev/null 2>&1; then
    header=$(od -An -v -t x1 -N 20 "$file" 2>/dev/null | tr -d ' \r\n') || true
  fi
  if [ "$header" != "????????????????????" ] && [ "${#header}" -ge 40 ]; then
    local magic="${header:0:8}"
    local elf_class="${header:8:2}"
    local machine="${header:36:4}"
    if [ "$magic" = "7f454c46" ] && [ "$elf_class" = "02" ] && [ "$machine" = "3e00" ]; then
      return 0
    fi
  fi
  return 1
}

select_node_runtime || {
  if command -v node >/dev/null 2>&1; then
    printf 'Node.js 22.19 or newer is required, got %s\n' "$(node -p 'process.versions.node')" >&2
  else
    printf '%s\n' 'Node.js 22.19 or newer is required, but node was not found.' >&2
  fi
  exit 1
}

node_version=$(node -p 'process.versions.node')
node_major=${node_version%%.*}
node_tail=${node_version#*.}
node_minor=${node_tail%%.*}
if [ "$node_major" -lt 22 ] || { [ "$node_major" -eq 22 ] && [ "$node_minor" -lt 19 ]; }; then
  printf 'Node.js 22.19 or newer is required, got %s\n' "$node_version" >&2
  exit 1
fi

source_root=${work_root}/source
pnpm_root=${work_root}/pnpm
landlock_root=${work_root}/landlock
runtime_root=${source_root}/.fnos-runtime
deploy_root=${work_root}/deploy
mkdir -p "$source_root" "$pnpm_root" "$landlock_root"
tar -xf "$source_archive" -C "$source_root"
tar -xzf "$pnpm_archive" -C "$pnpm_root"
tar -xzf "$landlock_archive" -C "$landlock_root"

for index in "${!source_patches[@]}"; do
  actual_patch_sha256=$(sha256sum "${source_patches[$index]}" | awk '{print $1}')
  [ "$actual_patch_sha256" = "${expected_patch_sha256s[$index]}" ] || {
    printf 'Source patch SHA-256 mismatch for %s: expected %s, got %s\n' \
      "${source_patches[$index]}" "${expected_patch_sha256s[$index]}" "$actual_patch_sha256" >&2
    exit 1
  }
done

pnpm_cli=${pnpm_root}/package/bin/pnpm.cjs
[ -f "$pnpm_cli" ] || { printf 'pnpm entry missing: %s\n' "$pnpm_cli" >&2; exit 1; }
# pnpm may re-exec itself for dependency-state checks. Expose the locked CLI to
# child processes without relying on a host-level pnpm or Corepack install.
pnpm_bin_root=${work_root}/pnpm-bin
mkdir -p "$pnpm_bin_root"
{
  printf '%s\n' '#!/bin/sh'
  printf 'exec node "%s" "$@"\n' "$pnpm_cli"
} > "$pnpm_bin_root/pnpm"
chmod 0755 "$pnpm_bin_root/pnpm"
export PATH="$pnpm_bin_root:$PATH"
pnpm_store_dir=${DSH_PNPM_STORE_DIR:-}
pnpm() {
  if [ -n "$pnpm_store_dir" ]; then
    pnpm_config_store_dir="$pnpm_store_dir" node "$pnpm_cli" "$@"
  else
    node "$pnpm_cli" "$@"
  fi
}

run_vitest_with_retries() {
  local max_attempts=$1
  shift
  local attempt=1
  while true; do
    if pnpm exec vitest run "$@"; then
      return 0
    fi
    if [ "$attempt" -ge "$max_attempts" ]; then
      return 1
    fi
    attempt=$((attempt + 1))
    printf 'vitest command failed, retrying (%s/%s): %s\n' "$attempt" "$max_attempts" "$*" >&2
  done
}

source_system_package=${source_root}/native/system/packages/linux-x64
official_landlock_package=${landlock_root}/package
official_landlock_launcher=${official_landlock_package}/bin/landlock-run
official_flock_addons="
bin/glibc/system.node
bin/musl/system.node
"
python3 - "$source_system_package/package.json" "$official_landlock_package/package.json" <<'PY'
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
    raise SystemExit("Official system package package.json differs beyond the repository organization rename")
PY
cmp -s "$official_landlock_package/prebuilds.json" "$source_system_package/prebuilds.json" || {
  printf 'Official system package metadata differs from locked source: prebuilds.json\n' >&2
  exit 1
}
[ -f "$official_landlock_launcher" ] || {
  printf 'Official landlock launcher missing: %s\n' "$official_landlock_launcher" >&2
  exit 1
}
[ -x "$official_landlock_launcher" ] || {
  printf 'Official landlock launcher is not executable: %s\n' "$official_landlock_launcher" >&2
  exit 1
}
check_elf_x86_64 "$official_landlock_launcher"
for flock_addon in $official_flock_addons; do
  [ -f "${official_landlock_package}/${flock_addon}" ] || {
    printf 'Official flock addon missing: %s\n' "${official_landlock_package}/${flock_addon}" >&2
    exit 1
  }
  check_elf_x86_64 "${official_landlock_package}/${flock_addon}"
done
install -D -m 0755 "$official_landlock_launcher" "${source_system_package}/bin/landlock-run"
for flock_addon in $official_flock_addons; do
  install -D -m 0644 "${official_landlock_package}/${flock_addon}" "${source_system_package}/${flock_addon}"
done

cd "$source_root"
# Keep git apply in no-index mode even when the work root lives inside a Git
# super-project (for example DSH_BUILD_WORK_ROOT under a repository checkout).
# Without this ceiling git resolves patch paths against the outer repository
# root and silently skips every hunk while still exiting 0.
export GIT_CEILING_DIRECTORIES="${GIT_CEILING_DIRECTORIES:-$work_root}"
for source_patch in "${source_patches[@]}"; do
  git apply --check --whitespace=error-all "$source_patch"
  git apply --whitespace=error-all "$source_patch"
done
pnpm --config.node-linker=hoisted install --frozen-lockfile
# The disposable build VM may enable systemd; upstream's tight timeout/abort
# coverage assumes the direct scope path (no user session bus), otherwise the
# systemd-run scope bootstrap deterministically exceeds the 50-100ms test
# windows. Packaged runtime behavior is unaffected: the NAS process keeps its
# own session bus. Build and test phases need no user bus either.
unset DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR
for test_target in "${patch_test_targets[@]}"; do
  case "$test_target" in
    ''|' '*|*' '|*'  '*)
      printf '%s\n' 'A locked source patch test target contains an empty path.' >&2
      exit 1
      ;;
  esac
  test_targets=()
  IFS=' ' read -r -a test_targets <<< "$test_target"
  [ "${#test_targets[@]}" -gt 0 ] || {
    printf '%s\n' 'A locked source patch test target must not be empty.' >&2
    exit 1
  }
  for focused_target in "${test_targets[@]}"; do
    [ -n "$focused_target" ] || {
      printf '%s\n' 'A locked source patch test target contains an empty path.' >&2
      exit 1
    }
    case "$focused_target" in
      -*) printf 'A locked source patch test target must not be an option: %s\n' "$focused_target" >&2; exit 1 ;;
      packages/*) ;;
      *) printf 'A locked source patch test target must be under packages/: %s\n' "$focused_target" >&2; exit 1 ;;
    esac
  done
  pnpm exec vitest run "${test_targets[@]}"
done
pnpm exec vitest run --config vitest.e2e.config.ts packages/sandbox/sandbox-local/tests/landlock.e2e.ts
DSH_BUILD_CLIENT_PROFILE=official DSH_CLIENT_COMMIT_HASH="$source_commit" pnpm run build
# build:native-system rebuilds the host-libc flock addon in-tree; the deployed
# runtime must carry the locked official binaries, so re-overlay them.
for flock_addon in $official_flock_addons; do
  install -D -m 0644 "${official_landlock_package}/${flock_addon}" "${source_system_package}/${flock_addon}"
done
pnpm exec vitest run apps/cli/tests/args.spec.ts
run_vitest_with_retries 3 --config vitest.e2e.config.ts apps/cli/tests/built-bin.e2e.ts
node "${script_dir}/generate-source-runtime.mjs" "$source_root" "$runtime_root"
# Adding the runtime importer can require peer metadata absent from a clean CI
# store. Prefer cached data but allow registry reads; never relax the lockfile.
pnpm --config.node-linker=hoisted install --prefer-offline --frozen-lockfile --ignore-scripts
# The deploy filter selects only the runtime closure, so the workspace-level patch
# declarations for packages outside it (electron signing, spreadsheet editing) would
# otherwise fail pnpm 11's unused-patch audit. Downgrade that audit to a warning for
# the deploy copy: the frozen install above already applied every patch the closure
# can reach, and the closure itself is verified by the packaged entry probes below.
pnpm --config.node-linker=hoisted --filter dsh-fnos-runtime --prod deploy --legacy --config.allowUnusedPatches=true "$deploy_root"

find "$deploy_root" -type d -name .bin -prune -exec rm -rf -- {} +
bash "${script_dir}/materialize-workspace-links.sh" "$source_root" "$deploy_root" "$pnpm_cli"
prune_summary=$(node "${script_dir}/prune-source-runtime.mjs" "$deploy_root")
find "$deploy_root" -type f \( -name '*.exe' -o -name '*.cmd' -o -name '*.dll' -o -name '*.pdb' \) -delete

dsh_entry=${deploy_root}/node_modules/@deepseek-ai/dsh/lib/bin.js
node_pty=${deploy_root}/node_modules/node-pty/prebuilds/linux-x64/pty.node
sharp_package_lib=${deploy_root}/node_modules/@img/sharp-linux-x64/lib
group_entry=${deploy_root}/node_modules/@deepseek-ai/cordis-plugin-group/lib/index.js
landlock_launcher=${deploy_root}/node_modules/@deepseek-ai/node-addon-system-linux-x64/bin/landlock-run
flock_addon=${deploy_root}/node_modules/@deepseek-ai/node-addon-system-linux-x64/bin/glibc/system.node
for required_file in "$dsh_entry" "$node_pty" "$group_entry" "$landlock_launcher" "$flock_addon"; do
  [ -f "$required_file" ] || { printf 'Required runtime file missing: %s\n' "$required_file" >&2; exit 1; }
done
mapfile -t sharp_nodes < <(find "$sharp_package_lib" -maxdepth 1 -type f -name '*.node' | sort)
[ "${#sharp_nodes[@]}" -eq 1 ] || {
  printf 'Expected exactly one sharp linux-x64 native addon in %s, got %s\n' "$sharp_package_lib" "${#sharp_nodes[@]}" >&2
  exit 1
}
sharp_node=${sharp_nodes[0]}
chmod 0755 "$landlock_launcher"
[ -x "$landlock_launcher" ] || { printf 'Landlock launcher is not executable: %s\n' "$landlock_launcher" >&2; exit 1; }
cmp -s "$official_landlock_launcher" "$landlock_launcher" || {
  printf '%s\n' 'Deployed landlock launcher differs from the locked official binary.' >&2
  exit 1
}
cmp -s "${official_landlock_package}/bin/glibc/system.node" "$flock_addon" || {
  printf '%s\n' 'Deployed flock addon differs from the locked official binary.' >&2
  exit 1
}

actual_dsh_version=$(DSH_HOME=${work_root}/dsh-home node "$dsh_entry" --version)
[ "$actual_dsh_version" = "$expected_dsh_version" ] || {
  printf 'DSH version mismatch: expected %s, got %s\n' "$expected_dsh_version" "$actual_dsh_version" >&2
  exit 1
}

check_elf_x86_64 "$node_pty"
check_elf_x86_64 "$sharp_node"
check_elf_x86_64 "$landlock_launcher"
check_elf_x86_64 "$flock_addon"
landlock_probe=$("$landlock_launcher" --probe)
case "$landlock_probe" in
  'landlock: fully enforced'|'landlock: partially enforced (older ABI)') ;;
  *) printf 'Unexpected Landlock probe result: %s\n' "$landlock_probe" >&2; exit 1 ;;
esac
(
  cd "$deploy_root"
  node -e "require('node-pty'); require('sharp')"
  node -e "Promise.all([import('@anthropic-ai/sdk'), import('@earendil-works/pi-ai'), import('@google/genai'), import('openai')]).catch(error => { console.error(error); process.exit(1) })"
)

mkdir -p "$(dirname -- "$runtime_archive")"
tar -czf "$runtime_archive" -C "$deploy_root" .
printf 'source runtime built: dsh=%s node=%s landlock=%s files=%s prune=%s\n' \
  "$actual_dsh_version" "$node_version" "$landlock_probe" "$(find "$deploy_root" -type f | wc -l)" "$prune_summary"
