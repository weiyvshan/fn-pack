#!/usr/bin/env bash
#
# Thin bash entry point for the fnOS project audit.
# Forwards every argument to the Python core next to this script, so callers
# keep a single, language-neutral command surface on Debian hosts.
set -uo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P) || {
    echo "audit_fnos_project.sh: cannot determine the script directory" >&2
    exit 1
}

python_bin="${PYTHON:-python3}"
if ! command -v "$python_bin" >/dev/null 2>&1; then
    echo "audit_fnos_project.sh: $python_bin was not found on PATH" >&2
    exit 1
fi

exec "$python_bin" "$script_dir/audit_fnos_project.py" "$@"
