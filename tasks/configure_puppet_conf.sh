#!/bin/bash
set -euo pipefail

PUPPET_CONF='/etc/puppetlabs/puppet/puppet.conf'

certname="${PT_certname:-$(hostname -f)}"
server="${PT_server:-$(hostname -f)}"
ca_server="${PT_ca_server:-}"
dns_alt_names="${PT_dns_alt_names:-}"
environment="${PT_environment:-}"

# Settings in [main] that move Puppet's directories are carried over from an
# existing file. Foreman's puppet.conf template, for one, puts vardir and
# ssldir under /var/lib/puppet on every OS. Dropped, they would send the agent
# to the default ssldir, where it finds no certificate and requests a new one
# under a certname the CA already holds. Values are kept as written, so
# `ssldir = $vardir/ssl` still follows vardir.
path_settings='vardir|ssldir|privatekeydir|publickeydir|certdir|requestdir|logdir|rundir|codedir'
kept=''
if [ -f "$PUPPET_CONF" ]; then
  kept=$(awk -v re="^[ \t]*(${path_settings})[ \t]*=" '
    /^[ \t]*\[/ { in_main = ($0 ~ /^[ \t]*\[main\][ \t]*$/); next }
    in_main && $0 ~ re { sub(/^[ \t]+/, ""); print }
  ' "$PUPPET_CONF")
fi

mkdir -p "$(dirname "$PUPPET_CONF")"

{
  printf '[main]\n'
  [ -n "$kept" ] && printf '%s\n' "$kept"
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

# The names of the settings carried over, as a JSON array. They come from the
# fixed list above, so they need no escaping.
kept_json=$(printf '%s\n' "$kept" | sed -n 's/^\([a-z]*\)[ \t]*=.*/"\1"/p' | paste -sd, -)

printf '{"status":"success","path":"%s","certname":"%s","server":"%s","environment":"%s","kept":[%s]}\n' \
  "$PUPPET_CONF" "$certname" "$server" "$environment" "$kept_json"
