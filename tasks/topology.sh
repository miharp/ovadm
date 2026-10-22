#!/bin/bash
# Report the deployment's topology as seen from the primary server: its
# certname and whether it is the CA, the compilers (signed certificates that
# carry pp_role=openvox_compiler, which ovadm::add_compiler requests), where
# the server sends OpenVoxDB traffic (puppetdb.conf), and where OpenVoxDB
# keeps its data (database.ini) if it runs on this host. Read-only, and works
# with the services stopped: everything comes from files and packages, so the
# same report can be taken on a host that is being backed up or restored.
set -euo pipefail

export PATH="/opt/puppetlabs/bin:$PATH"

pp_role_oid='1.3.6.1.4.1.34380.1.1.13'

# JSON string or null.
json_str() {
  if [ -z "${1:-}" ]; then
    printf 'null'
  else
    printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  fi
}

installed_version() {
  local pkg="$1" v
  v=$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || true)
  if [ -z "$v" ]; then
    v=$(rpm -q --queryformat '%{VERSION}-%{RELEASE}' "$pkg" 2>/dev/null) || v=''
  fi
  printf '%s' "$v"
}

# --- the server itself ---------------------------------------------------
if command -v puppet >/dev/null 2>&1; then
  certname=$(puppet config print certname --section server 2>/dev/null || true)
  confdir=$(puppet config print confdir --section server 2>/dev/null || true)
  cadir=$(puppet config print cadir --section server 2>/dev/null || true)
fi
certname=${certname:-$(hostname -f 2>/dev/null || hostname)}
confdir=${confdir:-/etc/puppetlabs/puppet}
cadir=${cadir:-/etc/puppetlabs/puppetserver/ca}

ca=false
[ -f "$cadir/ca_crt.pem" ] && ca=true

# --- compilers: signed certificates with pp_role=openvox_compiler ----------
compilers=''
server_role=''
if [ -d "$cadir/signed" ] && command -v openssl >/dev/null 2>&1; then
  for cert in "$cadir"/signed/*.pem; do
    [ -f "$cert" ] || continue
    name=$(basename "$cert" .pem)
    # openssl prints the unknown extension's OID on one line and its DER
    # value, with the leading type and length bytes as dots, on the next.
    role=$(openssl x509 -in "$cert" -noout -text 2>/dev/null \
      | grep -A1 "$pp_role_oid" | tail -n 1 | sed 's/^[[:space:].]*//' || true)
    if [ "$name" = "$certname" ]; then
      server_role="$role"
    elif [ "$role" = 'openvox_compiler' ]; then
      compilers="${compilers:+$compilers,}$(json_str "$name")"
    fi
  done
fi

# --- where the server sends OpenVoxDB traffic -----------------------------
server_urls=''
if [ -f "$confdir/puppetdb.conf" ]; then
  urls=$(awk -F= '/^[[:space:]]*server_urls[[:space:]]*=/ { sub(/^[^=]*=/, ""); gsub(/[[:space:]]/, ""); print; exit }' "$confdir/puppetdb.conf" || true)
  IFS=',' read -r -a url_list <<< "$urls"
  for u in "${url_list[@]}"; do
    [ -n "$u" ] && server_urls="${server_urls:+$server_urls,}$(json_str "$u")"
  done
fi

# --- OpenVoxDB on this host, and its database -----------------------------
openvoxdb_version=$(installed_version openvoxdb)
[ -n "$openvoxdb_version" ] || openvoxdb_version=$(installed_version puppetdb)
database='null'
database_ini='/etc/puppetlabs/puppetdb/conf.d/database.ini'
if [ -r "$database_ini" ]; then
  # subname = //HOST:PORT/DATABASE; the port is optional.
  subname=$(awk -F= '/^[[:space:]]*subname[[:space:]]*=/ { sub(/^[^=]*=/, ""); gsub(/[[:space:]]/, ""); print; exit }' "$database_ini" || true)
  db_user=$(awk -F= '/^[[:space:]]*username[[:space:]]*=/ { sub(/^[^=]*=/, ""); gsub(/[[:space:]]/, ""); print; exit }' "$database_ini" || true)
  if [ -n "$subname" ]; then
    rest=${subname#//}
    db_name=${rest##*/}
    hostport=${rest%%/*}
    db_host=${hostport%%:*}
    db_port=${hostport#*:}
    [ "$db_port" = "$hostport" ] && db_port=5432
    db_local=false
    case "$db_host" in
      localhost|127.0.0.1|::1|"$certname"|"$(hostname -f 2>/dev/null)"|"$(hostname)") db_local=true ;;
    esac
    database=$(printf '{"host":%s,"port":%s,"name":%s,"user":%s,"local":%s}' \
      "$(json_str "$db_host")" "$db_port" "$(json_str "$db_name")" "$(json_str "$db_user")" "$db_local")
  fi
fi

# --- PostgreSQL on this host ----------------------------------------------
# /usr/bin/postgres on EL, a versioned directory on Debian and with PGDG.
postgresql_version=''
for pg in /usr/bin/postgres /usr/lib/postgresql/*/bin/postgres /usr/pgsql-*/bin/postgres; do
  if [ -x "$pg" ]; then
    postgresql_version=$("$pg" --version 2>/dev/null | awk '{print $NF}' || true)
    break
  fi
done
pg_dump_present=false
command -v pg_dump >/dev/null 2>&1 && pg_dump_present=true

printf '{"certname":%s,"ca":%s,"server_role":%s,"compilers":[%s],"openvoxdb":{"server_urls":[%s],"version":%s,"database":%s},"postgresql":{"version":%s,"pg_dump":%s}}\n' \
  "$(json_str "$certname")" "$ca" "$(json_str "$server_role")" "$compilers" \
  "$server_urls" "$(json_str "$openvoxdb_version")" "$database" \
  "$(json_str "$postgresql_version")" "$pg_dump_present"
