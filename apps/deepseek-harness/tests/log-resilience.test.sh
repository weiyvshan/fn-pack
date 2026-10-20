#!/bin/sh
# Regression test for the resilience of the service log.
#
# The package install can hold the data volume read only for a short while.
# The shell treats a failed redirection as a fatal error, so a log that
# cannot be written must never take the service down with it.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

. "${SCRIPT_DIR}/../cmd/config-common"

UNWRITABLE=/nonexistent-directory-for-the-log-test/dsh.log
LOG_FILE=$UNWRITABLE
LOG_TARGET=$UNWRITABLE
ERROR_LOG=$UNWRITABLE

STDERR_FILE=$(mktemp "${TMPDIR:-/tmp}/deepseek-harness-log-stderr.XXXXXX")
WRITABLE=$(mktemp "${TMPDIR:-/tmp}/deepseek-harness-log-test.XXXXXX")
cleanup() {
  result=$?
  rm -f -- "$STDERR_FILE" "$WRITABLE"
  exit "$result"
}
trap cleanup EXIT HUP INT TERM

# The write must report the failure instead of killing the script.
if write_line_to_file "$UNWRITABLE" 'a line'; then
  fail 'a write to an unwritable path reported success'
fi

# The message must reach the standard error that the platform captures. The
# call runs in the current shell, because the fallback target is remembered
# there.
log_message 'a service message' 2>"$STDERR_FILE"
grep -Fq 'a service message' "$STDERR_FILE" ||
  fail 'the log message did not reach the standard error'

# A reported failure must not stop the script either.
report_error 'a reported failure' 2>>"$STDERR_FILE"
grep -Fq 'a reported failure' "$STDERR_FILE" ||
  fail 'the reported failure did not reach the standard error'

# The log target must have fallen back to the standard error.
[ "$LOG_TARGET" = '/dev/stderr' ] ||
  fail 'the log target did not fall back to the standard error'

# A writable log still goes to the log file.
LOG_FILE=$WRITABLE
LOG_TARGET=$WRITABLE
log_message 'a written message'
grep -Fq 'a written message' "$WRITABLE" ||
  fail 'a writable log did not receive the message'

printf '%s\n' 'log resilience tests passed'
