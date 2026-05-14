#!/bin/bash
set -euo pipefail

CSR_ATTRS='/etc/puppetlabs/puppet/csr_attributes.yaml'

pp_role="${PT_pp_role}"

mkdir -p "$(dirname "$CSR_ATTRS")"

printf 'extension_requests:\n  pp_role: %s\n' "$pp_role" > "$CSR_ATTRS"

printf '{"status":"success","path":"%s","pp_role":"%s"}\n' "$CSR_ATTRS" "$pp_role"
