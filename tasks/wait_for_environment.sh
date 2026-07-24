#!/bin/bash
set -euo pipefail

environment="${PT_environment:-production}"
timeout="${PT_timeout:-60}"

deadline=$(( $(date +%s) + timeout ))
while :; do
  # code-id succeeds once the agent has converged and created the environment
  # link. Until then it exits non-zero, which is codavox's no-fallback contract.
  if code_id="$(codavox code-id "$environment" 2>/dev/null)"; then
    printf '{"status":"success","environment":"%s","code_id":"%s"}\n' "$environment" "$code_id"
    exit 0
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    printf '{"status":"fail","error":"environment %s did not converge within %ss"}\n' "$environment" "$timeout"
    exit 1
  fi
  sleep 2
done
