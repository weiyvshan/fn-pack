#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
  printf '%s\n' 'usage: materialize-workspace-links.sh <source-root> <deploy-root> <pnpm-cli>' >&2
  exit 2
fi

source_root=$(realpath -e -- "$1")
deploy_root=$(realpath -e -- "$2")
pnpm_cli=$(realpath -e -- "$3")
modules_root=${deploy_root}/node_modules
[ -d "$modules_root" ] || { printf 'node_modules missing: %s\n' "$modules_root" >&2; exit 1; }

pack_root=$(mktemp -d "${deploy_root}/.workspace-packs.XXXXXXXX")
trap 'rm -rf -- "$pack_root"' EXIT HUP INT TERM
mapfile -d '' links < <(find "$modules_root" -type l -print0)

materialized=0
for link in "${links[@]}"; do
  relative=${link#"${modules_root}/"}
  case "$relative" in
    @*/*/*) printf 'Unexpected nested scoped runtime link: %s\n' "$relative" >&2; exit 1 ;;
    @*/*) ;;
    @*) printf 'Unexpected scoped runtime link: %s\n' "$relative" >&2; exit 1 ;;
    */*) printf 'Unexpected nested runtime link: %s\n' "$relative" >&2; exit 1 ;;
    '') printf '%s\n' 'Unexpected empty runtime link path.' >&2; exit 1 ;;
  esac

  target=$(realpath -e -- "$link")
  case "${target}/" in
    "${source_root}/"*) ;;
    *) printf 'Runtime link escapes the verified source tree: %s -> %s\n' "$link" "$target" >&2; exit 1 ;;
  esac

  manifest=${target}/package.json
  [ -f "$manifest" ] || { printf 'Workspace package manifest missing: %s\n' "$manifest" >&2; exit 1; }
  package_name=$(node -e "const p=require(process.argv[1]); if(typeof p.name!=='string') process.exit(1); process.stdout.write(p.name)" "$manifest")
  [ "$relative" = "$package_name" ] || {
    printf 'Runtime link/package mismatch: %s -> %s\n' "$relative" "$package_name" >&2
    exit 1
  }

  materialized=$((materialized + 1))
  pack_dir=${pack_root}/${materialized}
  mkdir -p "$pack_dir"
  (
    cd "$target"
    node "$pnpm_cli" --config.ignore-scripts=true pack --pack-destination "$pack_dir" --silent >/dev/null
  )
  mapfile -d '' archives < <(find "$pack_dir" -maxdepth 1 -type f -name '*.tgz' -print0)
  [ "${#archives[@]}" -eq 1 ] || {
    printf 'Expected one packed archive for %s, got %s\n' "$package_name" "${#archives[@]}" >&2
    exit 1
  }

  rm -- "$link"
  mkdir -p "$link"
  tar -xzf "${archives[0]}" --strip-components=1 -C "$link"
done

rm -rf -- "$pack_root"
trap - EXIT HUP INT TERM
if find "$deploy_root" -type l -print -quit | grep -q .; then
  printf '%s\n' 'The deployed runtime still contains symbolic links after materialization.' >&2
  find "$deploy_root" -type l -printf '%p -> %l\n' >&2
  exit 1
fi
printf 'materialized workspace packages: %s\n' "$materialized"
