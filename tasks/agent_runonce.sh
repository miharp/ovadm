#!/bin/bash
set -euo pipefail

export PATH="/opt/puppetlabs/bin:$PATH"

waitforcert="${PT_waitforcert:-30}"
environment="${PT_environment:-}"

if ! command -v puppet >/dev/null 2>&1; then
  printf '{"status":"not_installed","error":"puppet not installed"}\n'
  exit 0
fi

# With --environment the agent asks for that environment and nothing else.
# Without it, the agent prefers the environment the server assigned on its
# last run over the one in puppet.conf, and the server assigns production
# when the one asked for does not exist yet; so a node enrolled before its
# environment is deployed would stay on production, every run, silently.
args=(--test --waitforcert "$waitforcert" --no-daemonize)
if [ -n "$environment" ]; then
  args+=(--environment "$environment")
fi

exit_code=0
puppet agent "${args[@]}" >&2 || exit_code=$?

case "$exit_code" in
  0) status='no_changes' ;;
  2) status='changes_applied' ;;
  *) status='failed' ;;
esac

printf '{"status":"%s","exit_code":%d,"environment":"%s"}\n' "$status" "$exit_code" "$environment"
