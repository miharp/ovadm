#!/bin/bash
# Let the server compile catalogs while OpenVoxDB is unreachable, for the one
# agent run that brings OpenVoxDB back on a rebuilt host: sets
# soft_write_failure = true in puppetdb.conf (facts and catalogs that cannot
# be stored are logged, not fatal), keeping a copy of the file to put back
# afterwards. Modes: enable_if_unreachable (only when the first server_url
# does not answer), enable, restore (put the copy back).
set -euo pipefail

export PATH="/opt/puppetlabs/bin:$PATH"

mode="${PT_mode:-enable_if_unreachable}"

json_str() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }
fail() {
  printf '{"status":"failed","_error":{"kind":"ovadm/puppetdb-soft-writes","msg":%s}}\n' "$(json_str "$1")"
  exit 1
}

if command -v puppet >/dev/null 2>&1; then
  confdir=$(puppet config print confdir --section server 2>/dev/null || true)
fi
conf="${confdir:-/etc/puppetlabs/puppet}/puppetdb.conf"
copy="$conf.ovadm-restore"

case "$mode" in
  restore)
    if [ -f "$copy" ]; then
      mv -f "$copy" "$conf"
      printf '{"status":"restored","path":%s}\n' "$(json_str "$conf")"
    else
      printf '{"status":"nothing_to_restore","path":%s}\n' "$(json_str "$conf")"
    fi
    exit 0
    ;;
  enable|enable_if_unreachable) ;;
  *) fail "unknown mode '$mode' (enable_if_unreachable, enable, restore)" ;;
esac

if [ ! -f "$conf" ]; then
  printf '{"status":"no_puppetdb_conf","path":%s}\n' "$(json_str "$conf")"
  exit 0
fi

url=$(awk -F= '/^[[:space:]]*server_urls[[:space:]]*=/ { sub(/^[^=]*=/, ""); gsub(/[[:space:]]/, ""); print; exit }' "$conf" | cut -d, -f1)
if [ "$mode" = enable_if_unreachable ]; then
  if [ -z "$url" ]; then
    printf '{"status":"no_server_urls","path":%s}\n' "$(json_str "$conf")"
    exit 0
  fi
  if curl -sk --max-time 5 "${url%/}/status/v1/simple" 2>/dev/null | grep -q running; then
    printf '{"status":"not_needed","path":%s,"url":%s}\n' "$(json_str "$conf")" "$(json_str "$url")"
    exit 0
  fi
fi

[ -f "$copy" ] || cp -p "$conf" "$copy"
if grep -qE '^[[:space:]]*soft_write_failure[[:space:]]*=' "$conf"; then
  sed -i -E 's/^([[:space:]]*soft_write_failure[[:space:]]*=).*/\1 true/' "$conf"
elif grep -qE '^\[main\]' "$conf"; then
  sed -i -E '/^\[main\]/a soft_write_failure = true' "$conf"
else
  printf '[main]\nsoft_write_failure = true\n' >> "$conf"
fi
printf '{"status":"enabled","path":%s,"copy":%s,"url":%s}\n' "$(json_str "$conf")" "$(json_str "$copy")" "$(json_str "$url")"
