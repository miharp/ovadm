#!/bin/bash
set -euo pipefail

# Path is provisional — verify on a real OpenVox install
PUPPET_CONF='/etc/openvox/puppet.conf'

certname="${PT_certname:-$(hostname -f)}"
server="${PT_server:-$(hostname -f)}"
dns_alt_names="${PT_dns_alt_names:-}"

mkdir -p "$(dirname "$PUPPET_CONF")"

if [ -n "$dns_alt_names" ]; then
  cat > "$PUPPET_CONF" <<EOF
[main]
certname = ${certname}
server = ${server}

[server]
dns_alt_names = ${dns_alt_names}
EOF
else
  cat > "$PUPPET_CONF" <<EOF
[main]
certname = ${certname}
server = ${server}
EOF
fi

printf '{"status":"success","path":"%s","certname":"%s","server":"%s"}\n' \
  "$PUPPET_CONF" "$certname" "$server"
