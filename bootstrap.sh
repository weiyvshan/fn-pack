#!/usr/bin/env bash
# Fetch the locked upstream source and build the fnOS package.
# Contract: x86_64 Linux, Node >= 22.19, git, python3.
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LOCK="$ROOT/apps/deepseek-harness/runtime.lock.json"
UPSTREAM="$ROOT/vendor/upstream/deepseek-harness"

for tool in git python3 node; do
    command -v "$tool" >/dev/null 2>&1 || { echo "missing required tool: $tool" >&2; exit 1; }
done

[ -f "$LOCK" ] || { echo "runtime.lock.json not found: $LOCK" >&2; exit 1; }

read -r REPOSITORY COMMIT < <(python3 - "$LOCK" <<'PY'
import json, sys
lock = json.load(open(sys.argv[1], encoding='utf-8'))
print(lock['upstream_repository'], lock['upstream_commit'])
PY
)

echo "upstream repository: $REPOSITORY"
echo "locked commit:       $COMMIT"

if [ ! -d "$UPSTREAM/.git" ]; then
    mkdir -p "$(dirname -- "$UPSTREAM")"
    git clone --filter=blob:none --no-checkout "$REPOSITORY" "$UPSTREAM" 2>/dev/null ||
        { rm -rf "$UPSTREAM"; git clone --no-checkout "$REPOSITORY" "$UPSTREAM"; }
fi

git -C "$UPSTREAM" fetch origin "$COMMIT" 2>/dev/null || git -C "$UPSTREAM" fetch origin
git -C "$UPSTREAM" checkout --detach "$COMMIT"

ACTUAL=$(git -C "$UPSTREAM" rev-parse HEAD)
if [ "$ACTUAL" != "$COMMIT" ]; then
    echo "upstream commit mismatch: got $ACTUAL, want $COMMIT" >&2
    exit 1
fi
echo "upstream source ready at $ACTUAL"

exec bash "$ROOT/apps/deepseek-harness/scripts/build-fpk.sh" \
    --source-tree "$UPSTREAM" \
    --pnpm-tarball "$ROOT/vendor/runtime-cache/pnpm-11.28.5.tgz" \
    --landlock-tarball "$ROOT/vendor/runtime-cache/node-addon-system-linux-x64-0.1.2.tgz" \
    "$@"
