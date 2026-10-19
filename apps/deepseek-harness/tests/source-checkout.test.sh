#!/bin/sh
set -u

PROJECT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
RESOLVER="$PROJECT/scripts/resolve-upstream-source.sh"
SUBMODULE_PATH='vendor/upstream/deepseek-harness'
TEST_ROOT=''

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

remove_test_path() {
    target=$1
    case "$target" in
        "$TEST_ROOT"|"$TEST_ROOT"/*) rm -rf -- "$target" ;;
        *) fail "Unsafe test cleanup target: $target" ;;
    esac
}

cleanup() {
    if [ -n "$TEST_ROOT" ] && [ -d "$TEST_ROOT" ]; then
        remove_test_path "$TEST_ROOT"
    fi
}
trap cleanup EXIT HUP INT TERM

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "$1 was not found on PATH."
}

git_checked() {
    worktree=$1
    shift
    output=$(git -C "$worktree" "$@" 2>&1)
    status=$?
    [ "$status" -eq 0 ] || fail "git $* failed (exit $status): $output"
    printf '%s' "$output"
}

resolve_source() {
    "$RESOLVER" \
        --repository-root "$SUPERPROJECT" \
        --expected-repository "$UPSTREAM" \
        --expected-commit "$EXPECTED_COMMIT" \
        --expected-tree "$EXPECTED_TREE" \
        "$@"
}

assert_field() {
    output=$1
    field=$2
    expected=$3
    actual=$(printf '%s\n' "$output" | sed -n "s/^${field}=//p" | head -n 1)
    [ "$actual" = "$expected" ] ||
        fail "Resolver field $field mismatch (got [$actual], want [$expected])."
}

assert_resolver_failure() {
    expected=$1
    shift
    output=$(resolve_source "$@" 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "Expected resolver failure containing: $expected"
    printf '%s\n' "$output" | grep -qF -- "$expected" ||
        fail "Expected failure containing [$expected], got: $output"
}

require_command git
[ -x "$RESOLVER" ] || fail "Resolver is missing or not executable: $RESOLVER"

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/deepseek-harness-source-resolver-tests.XXXXXX") ||
    fail 'Unable to create the source resolver test directory.'
UPSTREAM="$TEST_ROOT/upstream"
SUPERPROJECT="$TEST_ROOT/superproject"
OVERRIDE="$TEST_ROOT/override"
SUBMODULE_ROOT="$SUPERPROJECT/$SUBMODULE_PATH"
mkdir -p "$UPSTREAM" "$SUPERPROJECT" || fail 'Unable to create test repositories.'

git_checked "$UPSTREAM" init --quiet >/dev/null
printf '%s\n' 'one' >"$UPSTREAM/version.txt"
git_checked "$UPSTREAM" add version.txt >/dev/null
git_checked "$UPSTREAM" -c user.name='Source Resolver Tests' \
    -c user.email=source-resolver@example.invalid commit --quiet \
    -m 'test: add first source revision' >/dev/null
FIRST_COMMIT=$(git_checked "$UPSTREAM" rev-parse HEAD)
printf '%s\n' 'two' >"$UPSTREAM/version.txt"
git_checked "$UPSTREAM" add version.txt >/dev/null
git_checked "$UPSTREAM" -c user.name='Source Resolver Tests' \
    -c user.email=source-resolver@example.invalid commit --quiet \
    -m 'test: add locked source revision' >/dev/null
EXPECTED_COMMIT=$(git_checked "$UPSTREAM" rev-parse HEAD)
EXPECTED_TREE=$(git_checked "$UPSTREAM" rev-parse 'HEAD^{tree}')

git_checked "$SUPERPROJECT" init --quiet >/dev/null
mkdir -p "$(dirname -- "$SUBMODULE_ROOT")"
git_checked "$SUPERPROJECT" clone --quiet "$UPSTREAM" "$SUBMODULE_PATH" >/dev/null
git_checked "$SUBMODULE_ROOT" checkout --quiet --detach "$EXPECTED_COMMIT" >/dev/null
printf '[submodule "deepseek-harness"]\n\tpath = %s\n\turl = %s\n' \
    "$SUBMODULE_PATH" "$UPSTREAM" >"$SUPERPROJECT/.gitmodules"
git_checked "$SUPERPROJECT" add .gitmodules >/dev/null
git_checked "$SUPERPROJECT" update-index --add --cacheinfo \
    "160000,$EXPECTED_COMMIT,$SUBMODULE_PATH" >/dev/null
git_checked "$SUPERPROJECT" -c user.name='Source Resolver Tests' \
    -c user.email=source-resolver@example.invalid commit --quiet \
    -m 'test: pin upstream submodule' >/dev/null

initialized=$(resolve_source) || fail 'Initialized submodule resolution failed.'
assert_field "$initialized" Kind submodule
assert_field "$initialized" Commit "$EXPECTED_COMMIT"

git_checked "$TEST_ROOT" clone --quiet "$UPSTREAM" "$OVERRIDE" >/dev/null
git_checked "$OVERRIDE" checkout --quiet --detach "$EXPECTED_COMMIT" >/dev/null
explicit=$(resolve_source --source-tree "$OVERRIDE") || fail 'Explicit source-tree resolution failed.'
assert_field "$explicit" Kind override
assert_field "$explicit" Commit "$EXPECTED_COMMIT"

printf '%s\n' 'dirty' >>"$SUBMODULE_ROOT/version.txt"
assert_resolver_failure 'must be clean'
git_checked "$SUBMODULE_ROOT" restore version.txt >/dev/null

git_checked "$SUBMODULE_ROOT" remote set-url origin 'https://example.invalid/wrong.git' >/dev/null
assert_resolver_failure 'Source origin mismatch'
git_checked "$SUBMODULE_ROOT" remote set-url origin "$UPSTREAM" >/dev/null

git_checked "$SUBMODULE_ROOT" checkout --quiet --detach "$FIRST_COMMIT" >/dev/null
assert_resolver_failure 'Source commit mismatch'
git_checked "$SUBMODULE_ROOT" checkout --quiet --detach "$EXPECTED_COMMIT" >/dev/null

remove_test_path "$SUBMODULE_ROOT"
assert_resolver_failure 'not initialized'
downloaded=$(resolve_source --allow-download) || fail 'Allow-download submodule initialization failed.'
assert_field "$downloaded" Kind submodule
assert_field "$downloaded" Commit "$EXPECTED_COMMIT"

printf '%s\n' 'source checkout resolver tests passed'
