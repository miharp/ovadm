#!/bin/bash
set -euo pipefail

export PATH="/opt/puppetlabs/bin:$PATH"

waitforcert="${PT_waitforcert:-30}"

if ! command -v puppet >/dev/null 2>&1; then
  printf '{"status":"not_installed","error":"puppet not installed"}\n'
  exit 0
fi

exit_code=0
puppet agent --test --waitforcert "$waitforcert" --no-daemonize >&2 || exit_code=$?

case "$exit_code" in
  0) status='no_changes' ;;
  2) status='changes_applied' ;;
  *) status='failed' ;;
esac

printf '{"status":"%s","exit_code":%d}\n' "$status" "$exit_code"
