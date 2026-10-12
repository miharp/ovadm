#!/bin/bash
set -euo pipefail

PUPPET_CONF='/etc/puppetlabs/puppet/puppet.conf'

certname="${PT_certname:-$(hostname -f)}"
server="${PT_server:-$(hostname -f)}"
ca_server="${PT_ca_server:-}"
dns_alt_names="${PT_dns_alt_names:-}"
environment="${PT_environment:-}"

mkdir -p "$(dirname "$PUPPET_CONF")"

{
  printf '[main]\n'
  printf 'certname = %s\n' "$certname"
  printf 'server = %s\n' "$server"
  [ -n "$ca_server" ] && printf 'ca_server = %s\n' "$ca_server"
  if [ -n "$dns_alt_names" ]; then
    printf '\n[server]\ndns_alt_names = %s\n' "$dns_alt_names"
  fi
  # The environment this node's agent asks the server for, from its first run
  # on. Unset, the agent uses the server's default (production). In [agent],
  # where `puppet config set environment --section agent` puts it, so that
  # the server side is not affected.
  if [ -n "$environment" ]; then
    printf '\n[agent]\nenvironment = %s\n' "$environment"
  fi
} > "$PUPPET_CONF"

printf '{"status":"success","path":"%s","certname":"%s","server":"%s","environment":"%s"}\n' \
  "$PUPPET_CONF" "$certname" "$server" "$environment"
