#!/bin/bash
set -euo pipefail

export PATH="/opt/puppetlabs/bin:$PATH"

# Create the CA with `puppetserver ca setup`, the way the PE installer does,
# before puppetserver ever starts. That produces a root certificate plus an
# intermediate signing certificate with a 15-year lifetime. Letting the service
# generate its own CA on first start instead yields a single self-signed
# certificate that expires with ca_ttl — five years by default.

subject_alt_names="${PT_subject_alt_names:-}"
certname="${PT_certname:-}"
ca_name="${PT_ca_name:-}"

if ! command -v puppetserver >/dev/null 2>&1; then
  printf '{"status":"not_installed","error":"puppetserver not installed"}\n'
  exit 0
fi

cadir=$(puppet config print cadir --section server 2>/dev/null || true)
[ -n "$cadir" ] || cadir='/etc/puppetlabs/puppetserver/ca'
ca_cert="${cadir}/ca_crt.pem"

# Reruns and upgrades must not touch an existing CA
if [ -f "$ca_cert" ]; then
  printf '{"status":"already_present","ca_cert":"%s"}\n' "$ca_cert"
  exit 0
fi

args=(ca setup)
if [ -n "$certname" ]; then
  args+=(--certname "$certname")
fi
if [ -n "$ca_name" ]; then
  args+=(--ca-name "$ca_name")
fi
if [ -n "$subject_alt_names" ]; then
  args+=(--subject-alt-names "$subject_alt_names")
fi

if ! output=$(puppetserver "${args[@]}" 2>&1); then
  printf '%s\n' "$output" >&2
  exit 1
fi

printf '{"status":"created","ca_cert":"%s","subject_alt_names":"%s"}\n' \
  "$ca_cert" "$subject_alt_names"
