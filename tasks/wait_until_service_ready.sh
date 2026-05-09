#!/bin/bash
set -euo pipefail

max_wait="${PT_max_wait:-300}"
interval=5
elapsed=0

while [ "$elapsed" -lt "$max_wait" ]; do
  if curl -sk --max-time 3 https://localhost:8140/status/v1/simple 2>/dev/null | grep -q 'running'; then
    printf '{"status":"ready","elapsed_seconds":%d}\n' "$elapsed"
    exit 0
  fi
  sleep "$interval"
  elapsed=$((elapsed + interval))
done

printf '{"status":"timeout","elapsed_seconds":%d}\n' "$elapsed"
exit 1
