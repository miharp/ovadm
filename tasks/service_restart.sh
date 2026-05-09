#!/bin/bash
set -euo pipefail

SVC='puppetserver'

if ! systemctl cat "$SVC" >/dev/null 2>&1; then
  printf '{"status":"not_installed","service":"%s"}\n' "$SVC"
  exit 0
fi

systemctl restart "$SVC" >&2
printf '{"status":"restarted","service":"%s"}\n' "$SVC"
