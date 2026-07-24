#!/bin/bash
set -euo pipefail

puppet='/opt/puppetlabs/bin/puppet'
conf='/etc/puppetlabs/puppetserver/conf.d/versioned-code.conf'

mkdir -p "$(dirname "$conf")"

# Both commands must be set, or neither; OpenVox Server throws at startup if
# exactly one is present.
cat > "$conf" <<'EOF'
versioned-code: {
    code-id-command: /usr/bin/codavox-code-id
    code-content-command: /usr/bin/codavox-code-content
}
EOF

# OpenVox Server reads code from codavox's environment path, and static catalogs
# must be on for the code_id to bind file content.
"$puppet" config set --section main environmentpath /opt/puppetlabs/codavox/environments >&2
"$puppet" config set --section server static_catalogs true >&2

printf '{"status":"success","conf":"%s"}\n' "$conf"
