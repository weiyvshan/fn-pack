#!/bin/sh
# Regression test for the browser authentication token.
#
# The backend answers the readiness probe before it has written the token, so
# the start must wait for the token instead of failing right away. The gateway
# proxy reads the token when it starts and refuses to run without it.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

. "${SCRIPT_DIR}/../cmd/config-common"

# The lifecycle helpers are read from the script, because they drive the
# service state and are not part of the shared library.
MAIN_SCRIPT="${SCRIPT_DIR}/../cmd/main"

# Extract the token helpers from the lifecycle script so they can be driven
# here without running a whole service.
extract_function() {
  name=$1
  sed -n "/^${name}() {/,/^}/p" "$MAIN_SCRIPT"
}

TOKEN_HELPERS=$(extract_function wait_for_auth_token)
TOKEN_HELPERS="$TOKEN_HELPERS
$(extract_function auth_token_is_usable)"

[ -n "$TOKEN_HELPERS" ] || fail 'The lifecycle script has no browser authentication token helpers'

# The start must wait for the token instead of checking for it right away.
# The backend answers the readiness probe before it writes the token, so an
# immediate check fails a start that is about to succeed.
grep -Fq 'if ! wait_for_auth_token; then' "$MAIN_SCRIPT" ||
  fail 'App Center startup does not wait for the browser authentication token'
if grep -Fq 'if [ ! -f "$AUTH_TOKEN_FILE" ]; then' "$MAIN_SCRIPT"; then
  fail 'App Center startup still checks for the browser authentication token right away'
fi

eval "$TOKEN_HELPERS"

FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/deepseek-harness-token-test.XXXXXX")
cleanup() {
  result=$?
  rm -rf -- "$FIXTURE"
  exit "$result"
}
trap cleanup EXIT HUP INT TERM

AUTH_TOKEN_FILE="$FIXTURE/web-auth.token"
AUTH_TOKEN_WAIT_SECONDS=5

# A token that never appears must be reported, not waited for forever.
if wait_for_auth_token; then
  fail 'a missing browser authentication token reported success'
fi

# A token that appears late must be waited for. The helper is driven in the
# background because it sleeps between the checks.
(
  sleep 2
  printf 'a-token\n' >"$AUTH_TOKEN_FILE"
  chmod 0600 "$AUTH_TOKEN_FILE"
) &
writer=$!

if ! wait_for_auth_token; then
  fail 'a late browser authentication token was not waited for'
fi
wait "$writer" 2>/dev/null || true

# The token must be usable the way the gateway proxy reads it.
if ! auth_token_is_usable; then
  fail 'a regular token file owned by the caller was rejected'
fi

# A token that other users can read is refused, the same way the proxy
# refuses it.
chmod 0644 "$AUTH_TOKEN_FILE"
if auth_token_is_usable; then
  fail 'a token file with loose permissions was accepted'
fi
chmod 0600 "$AUTH_TOKEN_FILE"

# A token that the caller does not own is refused.
if chown 1000:1000 "$AUTH_TOKEN_FILE" 2>/dev/null; then
  if [ "$(stat -c '%u' "$AUTH_TOKEN_FILE" 2>/dev/null || true)" != "$(id -u 2>/dev/null || true)" ]; then
    if auth_token_is_usable; then
      fail 'a token file that the caller does not own was accepted'
    fi
  fi
fi

printf '%s\n' 'browser authentication token tests passed'
