#!/bin/bash
set -euo pipefail

puppetdb_host="${PT_puppetdb_host}"
puppetdb_port="${PT_puppetdb_port:-8081}"
store_reports="${PT_store_reports:-true}"

puppet_conf_dir='/etc/puppetlabs/puppet'
puppet='/opt/puppetlabs/bin/puppet'

# Write puppetdb.conf
cat > "${puppet_conf_dir}/puppetdb.conf" <<EOF
[main]
server_urls = https://${puppetdb_host}:${puppetdb_port}
EOF

# Write routes.yaml
cat > "${puppet_conf_dir}/routes.yaml" <<'EOF'
---
master:
  facts:
    terminus: puppetdb
    cache: yaml
EOF

# Wire storeconfigs into puppet.conf
"$puppet" config set --section main storeconfigs true >/dev/null 2>&1
"$puppet" config set --section main storeconfigs_backend puppetdb >/dev/null 2>&1

if [ "$store_reports" = 'true' ]; then
  "$puppet" config set --section main reports puppetdb >/dev/null 2>&1
fi

chown puppet:puppet \
  "${puppet_conf_dir}/puppetdb.conf" \
  "${puppet_conf_dir}/routes.yaml"

printf '{"status":"success","puppetdb_url":"https://%s:%s"}\n' \
  "$puppetdb_host" "$puppetdb_port"
