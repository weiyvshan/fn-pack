#!/bin/sh
# Integration regression for CLIProxyAPI 8 legacy compatibility and v8 writes.
set -u

CLI_BIN=${CLI_PROXY_API_BIN:?Run scripts/test-package.sh to supply the locked binary}
TEST_ROOT=${TMPDIR:-/tmp}/cpa-manager-plus-v8-migration-$$
CONFIG_PATH="$TEST_ROOT/config.yaml"
LEGACY_PATH="$TEST_ROOT/legacy.yaml"
VERSIONED_PATH="$TEST_ROOT/versioned-legacy.yaml"
AUTH_DIR="$TEST_ROOT/auths"
PLUGIN_DIR="$TEST_ROOT/plugins"
LOG_PATH="$TEST_ROOT/cli-proxy-api.log"
RESPONSE_PATH="$TEST_ROOT/response"
PID=
MANAGEMENT_KEY='Management-Key-For-V8-Test-123456'
CLIENT_KEY='Client-Key-For-V8-Test-123456789'

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    if [ -f "$LOG_PATH" ]; then
        printf '%s\n' '--- CLIProxyAPI log ---' >&2
        tail -n 80 "$LOG_PATH" >&2 || :
    fi
    exit 1
}

stop_server() {
    [ -n "$PID" ] || return 0
    if kill -0 "$PID" 2>/dev/null; then
        kill "$PID" 2>/dev/null || :
        waited=0
        while kill -0 "$PID" 2>/dev/null && [ "$waited" -lt 50 ]; do
            sleep 0.1
            waited=$((waited + 1))
        done
        kill -0 "$PID" 2>/dev/null && fail "CLIProxyAPI process $PID did not stop after SIGTERM."
    fi
    wait "$PID" 2>/dev/null || :
    PID=
}

cleanup() {
    stop_server
    case "$TEST_ROOT" in
        "${TMPDIR:-/tmp}"/cpa-manager-plus-v8-migration-*) rm -rf -- "$TEST_ROOT" ;;
        *) printf 'Refusing to clean unexpected test root: %s\n' "$TEST_ROOT" >&2 ;;
    esac
}
trap cleanup EXIT HUP INT TERM

command -v curl >/dev/null 2>&1 || fail 'curl is required.'
command -v python3 >/dev/null 2>&1 || fail 'python3 is required to allocate an isolated test port.'
[ -x "$CLI_BIN" ] || fail "CLIProxyAPI test binary is missing or not executable: $CLI_BIN"

PORT=$(python3 - <<'PY'
import socket
with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
) || fail 'Unable to allocate an isolated test port.'
BASE_URL="http://127.0.0.1:$PORT"
mkdir -p "$AUTH_DIR" "$PLUGIN_DIR"

cat > "$LEGACY_PATH" <<EOF
host: "127.0.0.1"
port: $PORT
remote-management:
  allow-remote: true
  secret-key: "$MANAGEMENT_KEY"
  disable-control-panel: true
  disable-auto-update-panel: true
api-keys:
  - "$CLIENT_KEY"
auth-dir: "$AUTH_DIR"
debug: false
logging-to-file: false
usage-statistics-enabled: true
redis-usage-queue-retention-seconds: 3600
request-retry: 3
plugins:
  enabled: true
  dir: "$PLUGIN_DIR"
EOF

start_server() {
    : > "$LOG_PATH"
    (
        cd "$TEST_ROOT" || exit 1
        exec "$CLI_BIN" -config "$CONFIG_PATH"
    ) > "$LOG_PATH" 2>&1 &
    PID=$!
    waited=0
    while [ "$waited" -lt 100 ]; do
        if curl -fsS "$BASE_URL/healthz" >/dev/null 2>&1; then
            return 0
        fi
        kill -0 "$PID" 2>/dev/null || fail 'CLIProxyAPI exited before becoming healthy.'
        sleep 0.1
        waited=$((waited + 1))
    done
    fail 'CLIProxyAPI did not become healthy within 10 seconds.'
}

request() {
    expected=$1
    method=$2
    url=$3
    key=$4
    body=${5-}
    if [ -n "$body" ]; then
        actual=$(curl -sS -o "$RESPONSE_PATH" -w '%{http_code}' \
            -X "$method" -H "Authorization: Bearer $key" \
            -H 'Content-Type: application/json' --data "$body" "$BASE_URL$url") ||
            fail "$method $url transport failed."
    else
        actual=$(curl -sS -o "$RESPONSE_PATH" -w '%{http_code}' \
            -X "$method" -H "Authorization: Bearer $key" "$BASE_URL$url") ||
            fail "$method $url transport failed."
    fi
    [ "$actual" = "$expected" ] ||
        fail "$method $url returned HTTP $actual, expected $expected: $(cat "$RESPONSE_PATH")"
}

assert_keys_valid() {
    request 200 GET '/v8/management/config/routing/retry/request-retry' "$MANAGEMENT_KEY"
    request 401 GET '/v8/management/config' 'wrong-management-key'
    request 200 GET '/v1/models' "$CLIENT_KEY"
    request 401 GET '/v1/models' 'wrong-client-key'
}

assert_server_id() {
    request 200 GET '/v8/management/server/server-id' "$MANAGEMENT_KEY"
    python3 -B - "$RESPONSE_PATH" "$server_id" <<'PY' || fail 'Management API did not return the persisted server ID.'
import json
import sys

with open(sys.argv[1], encoding='utf-8') as response:
    if json.load(response).get('server-id') != sys.argv[2]:
        raise SystemExit('Server ID changed')
PY
}

# A pure legacy document starts and keeps the legacy schema. CLIProxyAPI 8.1
# persists server.server-id and hashes the plaintext management key at startup.
# Allow exactly those two changes before capturing the read-only baseline.
cp "$LEGACY_PATH" "$CONFIG_PATH"
start_server
server_id=$(python3 -B - "$LEGACY_PATH" "$CONFIG_PATH" <<'PY'
import re
import sys
from pathlib import Path
from uuid import UUID

legacy, actual = (Path(path).read_bytes() for path in sys.argv[1:])
identity = re.search(rb'^server:\n  server-id: ([0-9a-f-]{36})\n\Z', actual, re.MULTILINE)
if not identity:
    raise SystemExit('Expected a final server stanza containing only server-id')
value = identity[1].decode('ascii')
if UUID(value).version != 4 or str(UUID(value)) != value:
    raise SystemExit('Expected a canonical v4 server UUID')
without_identity = actual[:identity.start()]
normalized, count = re.subn(rb'^  secret-key: "?\$2[aby]\$[0-9]{2}\$[./A-Za-z0-9]{53}"?\n',
                           b'  secret-key: <normalized>\n', without_identity, flags=re.MULTILINE)
expected = re.sub(rb'^  secret-key: .*\n', b'  secret-key: <normalized>\n', legacy, flags=re.MULTILINE)
if count != 1 or normalized != expected:
    raise SystemExit('Legacy startup changed more than the management key hash and server ID')
print(value)
PY
) || fail 'Legacy startup did not preserve the legacy layout with a persisted identity.'
cp "$CONFIG_PATH" "$TEST_ROOT/baseline-legacy.yaml"
assert_keys_valid
assert_server_id
request 200 GET '/v8/management/config' "$MANAGEMENT_KEY"
if ! cmp -s "$CONFIG_PATH" "$TEST_ROOT/baseline-legacy.yaml"; then
    diff -u "$TEST_ROOT/baseline-legacy.yaml" "$CONFIG_PATH" >&2 || :
    fail 'A v8 management read migrated or rewrote the settled legacy document.'
fi
stop_server

# Declaring config-version alone enables no persistence side effect. Reuse the
# already-hashed legacy document so startup itself has nothing left to harden.
{
    printf 'config-version: 8\n'
    cat "$TEST_ROOT/baseline-legacy.yaml"
} > "$CONFIG_PATH"
cp "$CONFIG_PATH" "$VERSIONED_PATH"
start_server
cmp -s "$CONFIG_PATH" "$VERSIONED_PATH" ||
    fail 'Startup rewrote a versioned legacy document.'
assert_keys_valid
assert_server_id
request 200 GET '/v8/management/config.yaml' "$MANAGEMENT_KEY"
cmp -s "$CONFIG_PATH" "$VERSIONED_PATH" ||
    fail 'A v8 read rewrote a versioned legacy document.'

# The first successful v8 configuration mutation performs the migration.
request 200 PUT '/v8/management/config/routing/retry/request-retry' "$MANAGEMENT_KEY" '3'
waited=0
while [ "$waited" -lt 50 ]; do
    grep -Eq '^server:[[:space:]]*$' "$CONFIG_PATH" && break
    sleep 0.1
    waited=$((waited + 1))
done
grep -Eq '^config-version:[[:space:]]*8[[:space:]]*$' "$CONFIG_PATH" ||
    fail 'Successful v8 write did not persist config-version 8.'
grep -Eq '^server:[[:space:]]*$' "$CONFIG_PATH" || fail 'Successful v8 write did not create server.'
grep -Eq '^management:[[:space:]]*$' "$CONFIG_PATH" || fail 'Successful v8 write did not create management.'
grep -Eq '^access:[[:space:]]*$' "$CONFIG_PATH" || fail 'Successful v8 write did not create access.'
grep -Eq '^[[:space:]]+api-keys:[[:space:]]*$' "$CONFIG_PATH" ||
    fail 'Client keys were not migrated to access.api-keys.'
grep -Fq "$CLIENT_KEY" "$CONFIG_PATH" || fail 'Client API key disappeared during migration.'
grep -Eq '^[[:space:]]+secret-key:[[:space:]]*"?\$2[aby]\$' "$CONFIG_PATH" ||
    fail 'The hardened management key disappeared during migration.'
if grep -Eq '^(host|port|remote-management|auth-dir|debug|logging-to-file|usage-statistics-enabled|request-retry):' "$CONFIG_PATH"; then
    fail 'Successful v8 write left a mapped legacy field at the document root.'
fi
if grep -Eq '^api-keys:[[:space:]]*$' "$CONFIG_PATH"; then
    fail 'Client authentication keys were left at the provider-group root api-keys field.'
fi
assert_keys_valid
assert_server_id
stop_server
start_server
assert_keys_valid
assert_server_id

printf 'LegacyStartup=passed\n'
printf 'ServerIdentityPreserved=passed\n'
printf 'ReadDoesNotMigrate=passed\n'
printf 'VersionMarkerDoesNotMigrate=passed\n'
printf 'V8WriteMigrates=passed\n'
printf 'ClientKeyPreserved=passed\n'
printf 'ManagementKeyPreserved=passed\n'
