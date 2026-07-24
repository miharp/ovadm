#!/bin/bash
set -euo pipefail

staging="${PT_staging:-/etc/puppetlabs/code-staging}"
environment="${PT_environment:-production}"

envdir="${staging}/${environment}"
mkdir -p "${envdir}/manifests"

cat > "${envdir}/manifests/site.pp" <<'EOF'
node default {
  notify { 'codavox: this catalog was served through a static catalog': }
}
EOF

cat > "${envdir}/environment.conf" <<'EOF'
# Minimal environment seeded by ovadm::codavox so the publisher has something to
# serve. Replace with a real r10k-deployed control repo for fuller testing.
EOF

printf '{"status":"success","environment":"%s","path":"%s"}\n' "$environment" "$envdir"
