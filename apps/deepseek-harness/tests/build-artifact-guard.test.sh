#!/bin/sh
# Refusing a duplicate version must never delete the pre-existing artifact.
set -eu

PROJECT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/deepseek-harness-artifact-guard.XXXXXX")
cleanup() {
    case "$TEST_ROOT" in
        "${TMPDIR:-/tmp}"/deepseek-harness-artifact-guard.*) rm -rf -- "$TEST_ROOT" ;;
        *) printf 'Unsafe test cleanup path: %s\n' "$TEST_ROOT" >&2; exit 1 ;;
    esac
}
trap cleanup EXIT HUP INT TERM

FIXTURE="$TEST_ROOT/repo"
APP="$FIXTURE/apps/deepseek-harness"
mkdir -p "$APP/scripts" "$FIXTURE/.agents/skills/fnnas-app-creator/scripts" "$FIXTURE/build"
cp "$PROJECT/scripts/build-fpk.sh" "$APP/scripts/build-fpk.sh"
cp "$PROJECT/runtime.lock.json" "$PROJECT/manifest" "$APP/"
# Stop at the duplicate-artifact guard, without compiling or downloading anything.
printf '#!/bin/sh\nexit 0\n' > "$APP/scripts/test-package.sh"
for name in resolve-upstream-source.sh build-source-runtime.sh package-linux.sh check-summary-client.mjs; do
    : > "$APP/scripts/$name"
done
: > "$FIXTURE/.agents/skills/fnnas-app-creator/scripts/resolve-fnpack.sh"
version=$(sed -n 's/^version[[:space:]]*=[[:space:]]*//p' "$APP/manifest")
artifact="$FIXTURE/build/deepseek-harness_${version}_x86.fpk"
printf 'previous verified artifact\n' > "$artifact"
expected=$(sha256sum "$artifact" | cut -d ' ' -f1)
if sh "$APP/scripts/build-fpk.sh" > "$TEST_ROOT/output.log" 2>&1; then
    printf 'FAIL: an existing artifact must reject the build.\n' >&2
    exit 1
fi
grep -qF 'Refusing to overwrite existing artifact:' "$TEST_ROOT/output.log" || {
    printf 'FAIL: build did not reach the duplicate-artifact guard.\n' >&2
    exit 1
}
[ -f "$artifact" ] || { printf 'FAIL: refusing the build deleted the old artifact.\n' >&2; exit 1; }
[ "$(sha256sum "$artifact" | cut -d ' ' -f1)" = "$expected" ] || {
    printf 'FAIL: refusing the build modified the old artifact.\n' >&2
    exit 1
}
printf 'build artifact guard tests passed\n'
