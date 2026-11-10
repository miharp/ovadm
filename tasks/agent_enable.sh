#!/bin/bash
set -euo pipefail

export PATH="/opt/puppetlabs/bin:$PATH"

only_message="${PT_only_message:-}"

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
  printf '{"status":"not_installed","message":null}\n'
  exit 0
fi

disabled_lock=$(puppet config print agent_disabled_lockfile --section agent 2>/dev/null || true)
[ -n "$disabled_lock" ] || fail 'puppet config print agent_disabled_lockfile gave nothing; run puppet agent --enable on the host'

if [ ! -e "$disabled_lock" ]; then
  printf '{"status":"not_disabled","message":null}\n'
  exit 0
fi

current=$(sed -n 's/.*"disabled_message"[[:space:]]*:[[:space:]]*"\(.*\)"[[:space:]]*}.*/\1/p' "$disabled_lock" 2>/dev/null | head -n 1)

# Someone disabled the agent again, for a reason of their own, while the
# operation ran: that lock is theirs.
if [ -n "$only_message" ] && [ "${current#"$only_message"}" = "$current" ]; then
  printf '{"status":"left_disabled","message":%s}\n' "$(json_str "$current")"
  exit 0
fi

puppet agent --enable >&2 || fail 'puppet agent --enable failed; run it on the host'
printf '{"status":"enabled","message":%s}\n' "$(json_str "$current")"
