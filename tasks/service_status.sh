#!/bin/bash
# Report status of OpenVox Server services

set -euo pipefail

check_service() {
  local svc="$1"
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    printf '{"service":"%s","status":"running"}' "$svc"
  else
    printf '{"service":"%s","status":"stopped"}' "$svc"
  fi
}

puppetserver_json=$(check_service puppetserver)

printf '{"services":[%s]}\n' "$puppetserver_json"
