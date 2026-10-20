#!/bin/sh
# Regression test for the process group handling.
#
# The lifecycle script used to stop a service by signalling a single PID, so
# a child that the service spawned survived a stop. This drives the real
# helpers against a real process tree.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/deepseek-harness-group-test.XXXXXX")

cleanup() {
  result=$?
  for pid_file in "${FIXTURE}/parent.pid" "${FIXTURE}/child.pid"; do
    if [ -s "$pid_file" ]; then
      kill -KILL "$(cat "$pid_file")" 2>/dev/null || true
    fi
  done
  rm -rf -- "$FIXTURE"
  exit "$result"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

. "${SCRIPT_DIR}/../cmd/config-common"

# A parent that spawns a child and stays alive. The child is what a stop has
# to take down together with the parent. The parent is started in its own
# process group, the way the lifecycle script starts an owned process.
cat >"${FIXTURE}/tree.sh" <<EOS
#!/bin/sh
sh -c 'printf "%s\n" "\$\$" >"${FIXTURE}/child.pid"; sleep 120' &
printf '%s\n' "\$\$" >"${FIXTURE}/parent.pid"
wait
EOS
chmod 0755 "${FIXTURE}/tree.sh"

setsid sh "${FIXTURE}/tree.sh" >/dev/null 2>&1 &
i=0
while [ "$i" -lt 20 ]; do
  sleep 1
  i=$((i + 1))
  [ -s "${FIXTURE}/parent.pid" ] && [ -s "${FIXTURE}/child.pid" ] && break
done
[ -s "${FIXTURE}/parent.pid" ] || fail 'the parent process did not report its PID'
[ -s "${FIXTURE}/child.pid" ] || fail 'the child process did not report its PID'

parent=$(cat "${FIXTURE}/parent.pid")
child=$(cat "${FIXTURE}/child.pid")
kill -0 "$parent" 2>/dev/null || fail 'the parent process is not running'
kill -0 "$child" 2>/dev/null || fail 'the child process is not running'

# The parent leads its own process group, so the group can be signalled.
pgid=$(process_group_of "$parent" 2>/dev/null || true)
[ -n "$pgid" ] || fail 'the process group of the parent could not be read'
[ "$pgid" = "$parent" ] || fail 'the parent does not lead its own process group'

# The child shares the group of its parent.
child_pgid=$(process_group_of "$child" 2>/dev/null || true)
[ "$child_pgid" = "$pgid" ] || fail 'the child is not in the process group of its parent'

# Stop the tree the way the lifecycle script stops an owned process.
signal_owned_group "$parent" "$pgid" TERM
waited=0
while kill -0 "$parent" 2>/dev/null && [ "$waited" -lt 10 ]; do
  sleep 1
  waited=$((waited + 1))
done
if kill -0 "$parent" 2>/dev/null; then
  signal_owned_group "$parent" "$pgid" KILL
  sleep 1
fi

sleep 1
kill -0 "$parent" 2>/dev/null && fail 'the parent process survived the stop'
kill -0 "$child" 2>/dev/null && fail 'the child process survived the stop of its parent'

# A process that does not lead its group is signalled on its own, so the
# signal cannot reach the other members of its group.
sleep 120 &
victim=$!
victim_pgid=$(process_group_of "$victim" 2>/dev/null || true)
[ -n "$victim_pgid" ] || fail 'the process group of the victim could not be read'
[ "$victim_pgid" != "$victim" ] || fail 'the victim unexpectedly leads its own process group'
signal_owned_group "$victim" "$victim_pgid" TERM
sleep 1
kill -0 "$victim" 2>/dev/null && fail 'the victim process survived the signal'
kill -0 "$$" 2>/dev/null || fail 'a group signal reached the shell that runs the test'

printf '%s\n' 'process group tests passed'
