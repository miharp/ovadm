#!/bin/bash
set -euo pipefail

# Path is provisional — verify on a real OpenVox install
PUPPET_CONF='/etc/openvox/puppet.conf'

certname="${PT_certname:-$(hostname -f)}"
server="${PT_server:-$(hostname -f)}"
ca_server="${PT_ca_server:-}"
dns_alt_names="${PT_dns_alt_names:-}"

mkdir -p "$(dirname "$PUPPET_CONF")"

{
  printf '[main]\n'
  printf 'certname = %s\n' "$certname"
  printf 'server = %s\n' "$server"
  [ -n "$ca_server" ] && printf 'ca_server = %s\n' "$ca_server"
  if [ -n "$dns_alt_names" ]; then
    printf '\n[server]\ndns_alt_names = %s\n' "$dns_alt_names"
  fi
} > "$PUPPET_CONF"

printf '{"status":"success","path":"%s","certname":"%s","server":"%s"}\n' \
  "$PUPPET_CONF" "$certname" "$server"
