#!/bin/bash
set -euo pipefail

max_wait="${PT_max_wait:-300}"
with_puppetdb="${PT_puppetdb:-false}"
interval=5
elapsed=0

# OpenVoxDB's plain-text port, from its jetty.ini; 8080 unless changed.
pdb_port=$(sed -n 's/^[[:space:]]*port[[:space:]]*=[[:space:]]*//p' /etc/puppetlabs/puppetdb/conf.d/jetty.ini 2>/dev/null | head -1 | tr -d '[:space:]' || true)
pdb_port=${pdb_port:-8080}

answers() {
  curl -sk --max-time 3 "$1" 2>/dev/null | grep -q 'running'
}

# wait_for <url>: poll until the status endpoint says running or the time
# is up, counting on from where the previous wait left off.
wait_for() {
  while [ "$elapsed" -lt "$max_wait" ]; do
    answers "$1" && return 0
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  return 1
}

service=puppetserver
url=https://localhost:8140
log=/var/log/puppetlabs/puppetserver/puppetserver.log
services='["puppetserver"]'
if wait_for "$url/status/v1/simple"; then
  if [ "$with_puppetdb" != true ]; then
    printf '{"status":"ready","elapsed_seconds":%d,"services":%s}\n' "$elapsed" "$services"
    exit 0
  fi
  service=puppetdb
  url="http://localhost:$pdb_port"
  log=/var/log/puppetlabs/puppetdb/puppetdb.log
  services='["puppetserver","puppetdb"]'
  if wait_for "$url/status/v1/simple"; then
    printf '{"status":"ready","elapsed_seconds":%d,"services":%s}\n' "$elapsed" "$services"
    exit 0
  fi
fi

# Say why it did not come up. When the service fails to start, it logs an
# ERROR entry and then the exception, such as OpenVox Server's startup
# memory check's "java.lang.Error: Not enough available RAM ...". Report the
# last such entry from the recent log, with the exception line after it.
json_escape() {
  printf '%s' "$1" | tr -d '\000-\037' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

state=$(systemctl is-active "$service" 2>/dev/null || true)
state=${state:-unknown}

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
  reason="No error in ${log}; see journalctl -u ${service}."
fi

msg="${service} did not answer on ${url} within ${elapsed} seconds (service ${state}). ${reason}"

printf '{"status":"timeout","service":"%s","elapsed_seconds":%d,"service_state":"%s","last_error":"%s","_error":{"kind":"ovadm/service-not-ready","msg":"%s"}}\n' \
  "$service" "$elapsed" "$(json_escape "$state")" "$(json_escape "$last_error")" "$(json_escape "$msg")"
exit 1
