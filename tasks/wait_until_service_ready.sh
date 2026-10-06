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

# Say why it did not come up. When OpenVox Server fails to start, it logs an
# ERROR entry and then the exception, such as its startup memory check's
# "java.lang.Error: Not enough available RAM ...". Report the last such
# entry from the recent log, with the exception line after it.
json_escape() {
  printf '%s' "$1" | tr -d '\000-\037' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

state=$(systemctl is-active puppetserver 2>/dev/null || true)
state=${state:-unknown}

log=/var/log/puppetlabs/puppetserver/puppetserver.log
last_error=''
if [ -r "$log" ]; then
  last_error=$(tail -n 300 "$log" | awk '
    pending != "" {
      if ($0 ~ /^[A-Za-z0-9_.$]+(Error|Exception)(:|$)/) last = pending " " $0
      pending = ""
    }
    / ERROR / { sub(/^[^ ]+ ERROR (\[[^]]*\] )*/, ""); last = $0; pending = $0 }
    END { print last }' | cut -c1-600)
fi

if [ -n "$last_error" ]; then
  reason="Last error in ${log}: ${last_error}"
else
  reason="No error in ${log}; see journalctl -u puppetserver."
fi

msg="puppetserver did not answer on https://localhost:8140 within ${elapsed} seconds (service ${state}). ${reason}"

printf '{"status":"timeout","elapsed_seconds":%d,"service_state":"%s","last_error":"%s","_error":{"kind":"ovadm/service-not-ready","msg":"%s"}}\n' \
  "$elapsed" "$(json_escape "$state")" "$(json_escape "$last_error")" "$(json_escape "$msg")"
exit 1
