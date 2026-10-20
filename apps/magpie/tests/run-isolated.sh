#!/bin/bash
# Run against throwaway state and network namespaces, never the installed app.
set -euo pipefail
SOURCE="$(cd -- "$(dirname -- "$0")/.." && pwd -P)"
PROJECT="$(cd -- "${MAGPIE_TEST_PROJECT:-$SOURCE}" && pwd -P)"
[ "$#" -le 1 ] || { printf 'Usage: bash tests/run-isolated.sh [PREVIOUS_FPK]\n' >&2; exit 2; }
[ -f "$PROJECT/manifest" ] && [ -f "$PROJECT/cmd/main" ] && [ -x "$PROJECT/app/bin/magpie" ] || {
    printf 'MAGPIE_TEST_PROJECT must be a complete prepared project.\n' >&2
    exit 2
}
previous_args=()
if [ "$#" -eq 1 ]; then
    [ -f "$1" ] || { printf 'Previous FPK not found\n' >&2; exit 2; }
    previous_args=(--previous-fpk "$(readlink -f -- "$1")")
fi
SYSTEM_PATH=/usr/sbin:/usr/bin:/sbin:/bin
IP_COMMAND="$(PATH="$SYSTEM_PATH" command -v ip)" || { printf 'ip is required for isolated tests.\n' >&2; exit 2; }
[ -x "$IP_COMMAND" ] || { printf 'ip must resolve to an executable.\n' >&2; exit 2; }
# Only this allowlist reaches the namespace tests and their fixture processes.
test_env=(
    "PATH=$SYSTEM_PATH"
    "TMPDIR=${TMPDIR:-/tmp}"
    "MAGPIE_TEST_PROJECT=$PROJECT"
    "MAGPIE_TEST_PROVENANCE=$SOURCE/tests/fixtures/previous-main.provenance.json"
    "MAGPIE_TEST_HOST_NETNS=$(readlink /proc/self/ns/net)"
    "MAGPIE_TEST_IP=$IP_COMMAND"
)
/usr/bin/env -i "${test_env[@]}" /usr/bin/python3 -I -B "$SOURCE/tests/gateway_port.py" \
    --provenance "$SOURCE/tests/fixtures/previous-main.provenance.json" "${previous_args[@]}" --check-previous >/dev/null

/usr/bin/env -i "${test_env[@]}" /usr/bin/unshare -rn /bin/bash -c '
    "$MAGPIE_TEST_IP" link set lo up
    exec /usr/bin/unshare --user --map-user=1000 --map-group=1000 \
        /bin/bash "$1/tests/lifecycle.sh"
' isolated "$SOURCE"

/usr/bin/env -i "${test_env[@]}" /usr/bin/unshare -rn /bin/bash -c '
    "$MAGPIE_TEST_IP" link set lo up
    exec /usr/bin/unshare --user --map-user=1000 --map-group=1000 \
        /usr/bin/python3 -I -B "$1/tests/gateway_port.py" \
        --project "$2" --provenance "$MAGPIE_TEST_PROVENANCE" "${@:3}"
' isolated "$SOURCE" "$PROJECT" "${previous_args[@]}"
