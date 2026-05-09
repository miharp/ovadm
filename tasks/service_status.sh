#!/bin/bash
# Report status of OpenVox Server services

set -euo pipefail

SERVICES=(
  openvox-server
)

for svc in "${SERVICES[@]}"; do
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    echo "{\"service\": \"${svc}\", \"status\": \"running\"}"
  else
    echo "{\"service\": \"${svc}\", \"status\": \"stopped\"}"
  fi
done
