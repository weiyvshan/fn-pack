#!/bin/bash
set -euo pipefail
PROJECT=$(cd -- "$(dirname -- "$0")/.." && pwd)
ROOT=$(cd -- "$PROJECT/../.." && pwd)
SKILL="$ROOT/.agents/skills/fnnas-app-creator"
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || { echo 'Linux x86_64 required (WSL supported)' >&2; exit 1; }
python3 -B "$PROJECT/scripts/build-package.py" "$PROJECT" "$ROOT" "$SKILL"
