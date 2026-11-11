#!/bin/sh
set -eu
PROJECT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python3 -B -m unittest discover -s "$PROJECT/tests" -p 'test_*.py' -v
python3 -B "$PROJECT/scripts/check-source.py"
