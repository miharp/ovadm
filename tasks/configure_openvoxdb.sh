#!/bin/bash
set -euo pipefail

db_host="${PT_db_host:-localhost}"
db_port="${PT_db_port:-5432}"
db_name="${PT_db_name:-puppetdb}"
db_user="${PT_db_user:-puppetdb}"
db_password="${PT_db_password}"

conf_dir='/etc/puppetlabs/puppetdb/conf.d'
mkdir -p "$conf_dir"

cat > "${conf_dir}/database.ini" <<EOF
[database]
subname = //${db_host}:${db_port}/${db_name}
username = ${db_user}
password = ${db_password}
EOF

chown -R puppetdb:puppetdb "$conf_dir" 2>/dev/null || true

printf '{"status":"success","config":"%s/database.ini"}\n' "$conf_dir"
