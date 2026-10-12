#!/bin/bash
set -euo pipefail

export PATH="/opt/puppetlabs/bin:$PATH"

certname="${PT_certname}"

if ! command -v puppetserver >/dev/null 2>&1; then
  printf '{"status":"not_installed","error":"puppetserver not installed"}\n'
  exit 0
fi

# Try to sign; if it fails, check whether the cert is already signed: the CA
# autosigns, or the compiler was enrolled before. `puppetserver ca list` has
# no --signed flag; --all lists signed certificates and requests, one per
# line, the name first.
sign_stderr=$(puppetserver ca sign --certname "$certname" 2>&1) && sign_rc=0 || sign_rc=$?

if [[ $sign_rc -eq 0 ]]; then
  printf '{"status":"signed","certname":"%s"}\n' "$certname"
elif puppetserver ca list --all 2>/dev/null | grep -qE "^[[:space:]]*${certname}[[:space:]]+\("; then
  printf '{"status":"already_signed","certname":"%s"}\n' "$certname"
else
  printf '%s\n' "$sign_stderr" >&2
  exit "$sign_rc"
fi
