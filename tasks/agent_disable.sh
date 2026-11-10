#!/bin/bash
set -euo pipefail

export PATH="/opt/puppetlabs/bin:$PATH"

message="${PT_message:-ovadm operation in progress}"
reclaim="${PT_reclaim:-}"
max_wait="${PT_max_wait:-300}"

json_str() {
  if [ -z "${1:-}" ]; then
    printf 'null'
  else
    printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  fi
}
fail() {
  printf '{"status":"failed","_error":{"kind":"ovadm/agent","msg":%s}}\n' "$(json_str "$1")"
  exit 1
}

if ! command -v puppet >/dev/null 2>&1; then
  printf '{"status":"not_installed","disabled_here":false,"message":null,"waited":0}\n'
  exit 0
fi

disabled_lock=$(puppet config print agent_disabled_lockfile --section agent 2>/dev/null || true)
run_lock=$(puppet config print agent_catalog_run_lockfile --section agent 2>/dev/null || true)
[ -n "$disabled_lock" ] || fail 'puppet config print agent_disabled_lockfile gave nothing; cannot tell whether the agent is disabled'

# The message an agent was disabled with: the lock file is {"disabled_message":"..."}.
lock_message() {
  sed -n 's/.*"disabled_message"[[:space:]]*:[[:space:]]*"\(.*\)"[[:space:]]*}.*/\1/p' "$disabled_lock" 2>/dev/null | head -n 1
}

# An agent the operator disabled is left as it is, and stays disabled when
# the operation is over. One an earlier run of the same operation disabled
# and never got to enable again (the plan was interrupted) is taken over, so
# this run enables it at the end.
disabled_here=false
if [ -e "$disabled_lock" ]; then
  current=$(lock_message)
  if [ -n "$reclaim" ] && [ "${current#"$reclaim"}" != "$current" ]; then
    status='reclaimed'
    disabled_here=true
  else
    status='already_disabled'
  fi
else
  puppet agent --disable "$message" >&2 || fail 'puppet agent --disable failed; the agent is still enabled'
  status='disabled'
  disabled_here=true
  current="$message"
fi

# A run already under way holds the run lock, with its pid in it. A lock
# whose process is gone is stale and nothing to wait for.
run_in_progress() {
  local pid
  [ -n "$run_lock" ] && [ -e "$run_lock" ] || return 1
  pid=$(tr -cd '0-9' < "$run_lock" 2>/dev/null || true)
  if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
    return 1
  fi
  return 0
}

waited=0
while run_in_progress && [ "$waited" -lt "$max_wait" ]; do
  sleep 5
  waited=$((waited + 5))
done
if run_in_progress; then
  # Do not leave behind a lock this run took.
  if [ "$status" = 'disabled' ]; then
    puppet agent --enable >&2 || true
  fi
  fail "an agent run (pid $(tr -cd '0-9' < "$run_lock" 2>/dev/null || echo '?')) has not finished after ${max_wait} s; wait for it, then run this again"
fi

printf '{"status":"%s","disabled_here":%s,"message":%s,"waited":%d}\n' "$status" "$disabled_here" "$(json_str "$current")" "$waited"
