#!/usr/bin/env bash
# Discover all isolated skill regressions; never perform NAS runtime operations.
set -euo pipefail
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
python_bin="${PYTHON:-python3}"
export PYTHONDONTWRITEBYTECODE=1
"$python_bin" -B "$script_dir/validate_skill.py" "$script_dir/.."
exec "$python_bin" -B -m unittest discover -s "$script_dir" -p 'test_*.py' -v
