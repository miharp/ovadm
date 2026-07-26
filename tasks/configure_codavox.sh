#!/bin/bash
set -euo pipefail

role="${PT_role:?role is required}"
staging="${PT_staging:-/etc/puppetlabs/code/environments}"
publisher="${PT_publisher:-}"
ssldir="${PT_ssldir:-/etc/puppetlabs/puppet/ssl}"
certname="${PT_certname:-$(hostname -f)}"

conf='/etc/codavox/config.yaml'
mkdir -p "$(dirname "$conf")"

case "$role" in
  publisher)
    cat > "$conf" <<EOF
staging: ${staging}
ssldir: ${ssldir}
certname: ${certname}
EOF
    ;;
  agent)
    if [ -z "$publisher" ]; then
      printf '{"status":"fail","error":"publisher is required for the agent role"}\n'
      exit 1
    fi
    cat > "$conf" <<EOF
ssldir: ${ssldir}
certname: ${certname}

agent:
  publisher: ${publisher}
EOF
    ;;
  *)
    printf '{"status":"fail","error":"unknown role %s"}\n' "$role"
    exit 1 ;;
esac

printf '{"status":"success","path":"%s","role":"%s"}\n' "$conf" "$role"
