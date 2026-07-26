#!/bin/bash
set -euo pipefail

staging="${PT_staging:-/etc/puppetlabs/code/environments}"
environment="${PT_environment:-production}"

envdir="${staging}/${environment}"
sitepp="${envdir}/manifests/site.pp"

# The staging directory is r10k's basedir, which on a stock install is the live
# codedir. So this must never overwrite code that is already there: a demo
# manifest replacing a real control repo would be a silent, destructive
# surprise, and codavox would then faithfully distribute the wrong tree to every
# compiler. An environment that already has manifests is left exactly as it is.
if [ -s "$sitepp" ]; then
  printf '{"status":"success","environment":"%s","path":"%s","seeded":false,"reason":"site.pp already exists; left untouched"}\n' \
    "$environment" "$envdir"
  exit 0
fi

mkdir -p "${envdir}/manifests"

cat > "$sitepp" <<'MANIFEST'
node default {
  notify { 'codavox: this catalog was served through a static catalog': }
}
MANIFEST

if [ ! -e "${envdir}/environment.conf" ]; then
  cat > "${envdir}/environment.conf" <<'ENVCONF'
# Minimal environment seeded by ovadm::codavox so the publisher has something to
# serve. Replace with a real r10k-deployed control repo for fuller testing.
ENVCONF
fi

printf '{"status":"success","environment":"%s","path":"%s","seeded":true}\n' "$environment" "$envdir"
