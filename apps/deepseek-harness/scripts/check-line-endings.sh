#!/usr/bin/env bash
# Repository-wide line-ending guard.
#
# The package is built and run on Linux, and the locked upstream source patches
# are applied with `git apply`, which requires LF bytes. A CRLF working tree
# therefore breaks the build, so every tracked text file must stay LF.
#
# Only the working tree is checked: the Git attributes normalise the index to
# LF on every commit, so the index cannot hold CRLF. The build reads the
# working tree, which is what this guard protects.
set -euo pipefail

REPO_ROOT=${1:-$(git rev-parse --show-toplevel)}
cd "$REPO_ROOT"

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  printf 'SKIP: not a Git work tree: %s\n' "$REPO_ROOT" >&2
  exit 0
fi

status=0
while IFS= read -r -d '' file; do
  [ -f "$file" ] || continue
  case $(git check-attr text -- "$file" | sed 's/.*: //') in
    set|auto) ;;
    *) continue ;;
  esac
  if grep -qU $'\r' "$file" 2>/dev/null; then
    printf 'CRLF line endings are not allowed in tracked text files: %s\n' "$file" >&2
    status=1
  fi
done < <(git ls-files -z)

if [ "$status" -ne 0 ]; then
  exit 1
fi

printf 'line-ending guard passed\n'
