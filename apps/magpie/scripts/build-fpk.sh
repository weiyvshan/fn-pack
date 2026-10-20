#!/usr/bin/env bash
# Assemble the pinned upstream CLI without changing the maintained runtime tree.
set -euo pipefail
# SDK-generated app.tgz must not inherit a private application umask.
umask 022

PROJECT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
REPO_ROOT=$(CDPATH= cd -- "$PROJECT/../.." && pwd -P)
SKILL_ROOT="$REPO_ROOT/.agents/skills/fnnas-app-creator"
TMP_ROOT="$REPO_ROOT/.tmp"
BUILD_ROOT="$REPO_ROOT/build"
WORK=

fail() {
    printf 'build-fpk: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    local status=$?
    if [[ -n "$WORK" && -d "$WORK" && ! -L "$WORK" ]]; then
        local resolved
        resolved=$(readlink -f -- "$WORK")
        case "$resolved" in
            "$TMP_ROOT"/magpie-build.*) rm -rf -- "${resolved:?}" ;;
            *) printf 'Unexpected cleanup directory: %s\n' "$resolved" >&2; status=1 ;;
        esac
    fi
    exit "$status"
}
trap cleanup EXIT

for tool in python3 jq curl ss setpriv pgrep flock unshare ip tar sha256sum; do
    command -v "$tool" >/dev/null || fail "Missing required tool: $tool"
done
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || fail 'The bundled SDK requires Linux x86-64.'
[[ -f "$SKILL_ROOT/scripts/resolve-fnpack.sh" ]] || fail 'The bundled fnpack resolver is missing.'
[[ -f "$SKILL_ROOT/scripts/audit_fnos_project.sh" ]] || fail 'The shared project auditor is missing.'
read -r APP VERSION PLATFORM < <(python3 -I -B - "$PROJECT/manifest" <<'PY'
from pathlib import Path
import re, sys
fields = {}
for line in Path(sys.argv[1]).read_text().splitlines():
    if '=' in line and not line.lstrip().startswith(';'):
        key, value = line.split('=', 1)
        fields[key.strip()] = value.strip()
assert fields['appname'] == 'magpie' and fields['platform'] == 'x86'
assert re.fullmatch(r'[0-9]+(?:\.[0-9]+)+(?:-[0-9]+)?', fields['version'])
print(fields['appname'], fields['version'], fields['platform'])
PY
)
TARGET="$BUILD_ROOT/${APP}_${VERSION}_${PLATFORM}.fpk"
[[ ! -e "$TARGET" && ! -L "$TARGET" ]] || fail "Existing artifact is preserved: $TARGET"
mkdir -p "$TMP_ROOT" "$BUILD_ROOT"
TMP_ROOT=$(CDPATH= cd -- "$TMP_ROOT" && pwd -P)
export TMPDIR="$TMP_ROOT"

python3 -I -B "$PROJECT/tests/binary-cache.test.py"
python3 -I -B "$PROJECT/tests/fpk-metadata.test.py"
python3 -I -B "$PROJECT/scripts/prepare-binary.py" --cache-dir "$TMP_ROOT/magpie-binaries"
UPSTREAM_VERSION=$(python3 -I -B -c 'import json,sys; print(json.load(open(sys.argv[1]))["upstream_version"])' "$PROJECT/binary.lock.json")
BINARY="$TMP_ROOT/magpie-binaries/magpie/$UPSTREAM_VERSION/magpie"
WORK=$(mktemp -d "$TMP_ROOT/magpie-build.XXXXXX")
STAGE="$WORK/project"
mkdir -p "$STAGE"
for directory in app cmd config wizard; do
    cp -a -- "$PROJECT/$directory" "$STAGE/$directory"
done
for file in manifest LICENSE ICON.PNG ICON_256.PNG; do
    cp -- "$PROJECT/$file" "$STAGE/$file"
done
mkdir -p "$STAGE/app/bin"
cp -- "$BINARY" "$STAGE/app/bin/magpie"
python3 -I -B - "$STAGE" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
root.chmod(0o755)
for path in root.rglob('*'):
    if path.is_symlink():
        raise SystemExit(f'Unexpected staging symlink: {path}')
    executable = path.parent == root / 'cmd' or path == root / 'app/bin/magpie'
    path.chmod(0o755 if path.is_dir() or executable else 0o644)
PY

printf 'Testing the complete staging tree\n'
MAGPIE_TEST_PROJECT="$STAGE" bash "$PROJECT/tests/run-isolated.sh"
bash "$SKILL_ROOT/scripts/audit_fnos_project.sh" --project-path "$STAGE" --format json > "$TMP_ROOT/magpie-stage-audit.json"
python3 -I -B - "$TMP_ROOT/magpie-stage-audit.json" <<'PY'
import json, sys
report = json.load(open(sys.argv[1]))
print('StagingAudit=' + json.dumps(report['summary'], sort_keys=True))
if report['summary']['total']:
    raise SystemExit('Review all staging audit findings before distribution')
PY

FNPACK=$(bash "$SKILL_ROOT/scripts/resolve-fnpack.sh" --bundled-only)
mkdir -p "$WORK/artifacts" "$WORK/sdk-tmp"
# The SDK derives archive directory modes from its temporary root.
chmod 0755 "$WORK/sdk-tmp"
(cd "$WORK/artifacts" && TMPDIR="$WORK/sdk-tmp" "$FNPACK" build --directory "$STAGE")
RAW="$WORK/artifacts/$APP.fpk"
NAMED="$WORK/artifacts/${APP}_${VERSION}_${PLATFORM}.fpk"
[[ -f "$RAW" && ! -L "$RAW" ]] || fail 'fnpack did not produce a regular package.'
# Canonicalize only the SDK-generated outer member mode; keep its payload.
python3 -I -B "$PROJECT/scripts/normalize-fpk.py" "$RAW" "$NAMED"
python3 -I -B "$PROJECT/tests/verify_fpk.py" "$NAMED" --project "$STAGE" --lock "$PROJECT/binary.lock.json" > "$TMP_ROOT/magpie-verification.json"

# Repeat lifecycle checks on the actual SDK output, not only its inputs.
UNPACKED="$WORK/unpacked"
mkdir -p "$UNPACKED/app"
tar -xf "$NAMED" -C "$UNPACKED"
tar -xzf "$UNPACKED/app.tgz" -C "$UNPACKED/app"
printf 'Testing the verified FPK payload\n'
MAGPIE_TEST_PROJECT="$UNPACKED" bash "$PROJECT/tests/run-isolated.sh"

# link() fails rather than replacing a concurrently created same-version FPK.
ln -T -- "$NAMED" "$TARGET"
printf 'Artifact=%s\nVersion=%s\nSHA256=' "$TARGET" "$VERSION"
sha256sum "$TARGET"
printf 'Result=passed\n'
