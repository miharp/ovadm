#!/bin/bash
# Take a backup of an OpenVox primary server: one archive holding the files
# of the selected items, a manifest describing the host they came from, and
# the topology the server sees. Self-contained on purpose: every input is a
# PT_* variable with a default, so the same script runs from a Bolt task or
# from a timer, and it needs only coreutils, tar and gzip. The topology comes
# from topology.sh beside this script, which Bolt ships as a task file.
#
# Archive layout, under one directory named like the archive:
#   files/            the copied paths, as they are on the host
#   ovadm/manifest.json
#   ovadm/topology.json
#   ovadm/SHA256SUMS  every file above, for backup_verify
set -euo pipefail
umask 077

export PATH="/opt/puppetlabs/bin:$PATH"

destination="${PT_destination:-/var/backups/openvox}"
want_ca="${PT_ca:-true}"
want_config="${PT_config:-true}"
want_code="${PT_code:-true}"
include_code_tree="${PT_include_code_tree:-false}"
extra_paths="${PT_extra_paths:-}"
stop_services="${PT_stop_services:-false}"
age_recipient="${PT_age_recipient:-}"
ovadm_version="${PT_ovadm_version:-}"

# --- JSON helpers ------------------------------------------------------------
json_str() {
  if [ -z "${1:-}" ]; then
    printf 'null'
  else
    printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  fi
}
# Lines on stdin to a JSON array of strings.
json_lines() {
  local out='' line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    out="${out:+$out,}$(json_str "$line")"
  done
  printf '[%s]' "$out"
}
fail() {
  printf '{"status":"failed","_error":{"kind":"ovadm/backup","msg":%s}}\n' "$(json_str "$1")"
  exit 1
}
warnings=()
warn() { warnings+=("$1"); }

installed_version() {
  local pkg="$1" v
  v=$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || true)
  if [ -z "$v" ]; then
    v=$(rpm -q --queryformat '%{VERSION}-%{RELEASE}' "$pkg" 2>/dev/null) || v=''
  fi
  printf '%s' "$v"
}
# Read one setting from an ini-style file: ini_get FILE KEY
ini_get() {
  awk -F= -v key="$2" '$1 ~ "^[[:space:]]*"key"[[:space:]]*$" { sub(/^[^=]*=/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print; exit }' "$1" 2>/dev/null || true
}

[ "$want_ca" = true ] || [ "$want_config" = true ] || [ "$want_code" = true ] \
  || fail 'nothing to back up: ca, config and code are all off'
if [ -n "$age_recipient" ] && ! command -v age >/dev/null 2>&1; then
  fail 'age_recipient is set but age is not installed on this host'
fi
command -v tar >/dev/null 2>&1 || fail 'tar is not installed'

# --- where things are ----------------------------------------------------------
if command -v puppet >/dev/null 2>&1; then
  certname=$(puppet config print certname --section server 2>/dev/null || true)
  cadir=$(puppet config print cadir --section server 2>/dev/null || true)
  ssldir=$(puppet config print ssldir --section server 2>/dev/null || true)
  codedir=$(puppet config print codedir --section server 2>/dev/null || true)
  agent_environment=$(puppet config print environment --section agent 2>/dev/null || true)
fi
hostname_fqdn=$(hostname -f 2>/dev/null || hostname)
certname=${certname:-$hostname_fqdn}
cadir=${cadir:-/etc/puppetlabs/puppetserver/ca}
ssldir=${ssldir:-/etc/puppetlabs/puppet/ssl}
codedir=${codedir:-/etc/puppetlabs/code}
agent_environment=${agent_environment:-production}
puppetdb_ssl='/etc/puppetlabs/puppetdb/ssl'
etc_root='/etc/puppetlabs'
database_ini='/etc/puppetlabs/puppetdb/conf.d/database.ini'

# The paths tar takes, relative to /, and the ones it leaves out.
paths=()
excludes=()
add_path() { [ -e "$1" ] && paths+=("${1#/}"); return 0; }
add_exclude() { excludes+=("--exclude=${1#/}"); }

take_tree=false
[ "$want_code" = true ] && [ "$include_code_tree" = true ] && take_tree=true

if [ "$want_config" = true ]; then
  [ -d "$etc_root" ] || fail "$etc_root does not exist; is OpenVox installed?"
  add_path "$etc_root"
  for f in /etc/sysconfig/puppetserver /etc/sysconfig/puppetdb /etc/default/puppetserver /etc/default/puppetdb; do
    add_path "$f"
  done
  [ "$take_tree" = true ] || add_exclude "$codedir"
  if [ "$want_ca" != true ]; then
    add_exclude "$cadir"
    add_exclude "$ssldir"
    add_exclude "$puppetdb_ssl"
  fi
else
  if [ "$want_ca" = true ]; then
    add_path "$cadir"
    add_path "$ssldir"
    add_path "$puppetdb_ssl"
  fi
  [ "$take_tree" = true ] && add_path "$codedir"
fi
if [ "$want_ca" = true ] && [ ! -f "$cadir/ca_crt.pem" ]; then
  warn "no CA at $cadir/ca_crt.pem; the archive holds no CA"
fi

extra_list=()
if [ -n "$extra_paths" ]; then
  IFS=',' read -r -a extra_list <<< "$extra_paths"
  for p in "${extra_list[@]}"; do
    [ -n "$p" ] || continue
    case "$p" in
      /*) ;;
      *) fail "extra path '$p' is not absolute" ;;
    esac
    [ -e "$p" ] || fail "extra path '$p' does not exist"
    add_path "$p"
  done
fi
# A code-only backup copies no tree, just the record below.
[ "${#paths[@]}" -gt 0 ] || [ "$want_code" = true ] || fail 'none of the selected paths exist on this host'

# --- services ---------------------------------------------------------------------
stopped=()
service_active() {
  command -v systemctl >/dev/null 2>&1 || return 1
  case "$(systemctl is-active "$1" 2>/dev/null)" in
    active|activating|reloading|deactivating) return 0 ;;
  esac
  return 1
}
start_services() {
  local svc
  for svc in "${stopped[@]}"; do
    systemctl start "$svc" >&2 || true
  done
  stopped=()
}
work=''
cleanup() {
  start_services
  [ -n "$work" ] && rm -rf "$work"
}
trap cleanup EXIT

if [ "$stop_services" = true ]; then
  for svc in puppetserver puppetdb; do
    if service_active "$svc"; then
      systemctl stop "$svc" >&2 || fail "could not stop $svc"
      stopped+=("$svc")
    fi
  done
fi

# --- copy ---------------------------------------------------------------------------
install -d -m 0700 "$destination" || fail "cannot create $destination"
created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
stamp=$(date -u +%Y%m%dT%H%M%SZ)
name="openvox-backup-${certname}-${stamp}"
work=$(mktemp -d "$destination/.backup.XXXXXX")
stage="$work/$name"
mkdir -p "$stage/files" "$stage/ovadm"

serial_before=''
[ -f "$cadir/serial" ] && serial_before=$(tr -d '[:space:]' < "$cadir/serial")

# Through a pipe rather than cp, so owners and modes survive and the
# excludes apply to whole subtrees. Relative names, so tar has nothing to
# strip and nothing to warn about.
if [ "${#paths[@]}" -gt 0 ] && ! tar -C / --anchored "${excludes[@]}" -cf - "${paths[@]}" | tar -C "$stage/files" -xpf -; then
  fail 'copying the files failed'
fi

# The record of what r10k deployed, in place, when the tree itself is not
# taken. The environment's own hiera.yaml names the eyaml keys, so it comes
# too. Through tar without recursion, naming the directories as well as the
# files, so the archive holds the directories with their real owners and
# modes: a restore applies directory metadata from the archive, and a chain
# made up on the fly here would come back root-only, unreadable to the
# server.
if [ "$want_code" = true ] && [ "$take_tree" != true ] && [ -d "$codedir/environments" ]; then
  record=("${codedir#/}" "${codedir#/}/environments")
  for envdir in "$codedir"/environments/*/; do
    [ -d "$envdir" ] || continue
    env_rel=${envdir#/}; env_rel=${env_rel%/}
    env_files=()
    for f in .r10k-deploy.json hiera.yaml; do
      [ -f "$envdir$f" ] && env_files+=("$env_rel/$f")
    done
    [ "${#env_files[@]}" -gt 0 ] && record+=("$env_rel" "${env_files[@]}")
  done
  if [ "${#record[@]}" -gt 2 ] && ! tar -C / --no-recursion -cf - "${record[@]}" | tar -C "$stage/files" -xpf -; then
    fail 'copying the code record failed'
  fi
fi
# r10k's own configuration belongs with the code: a rebuilt host deploys the
# code before its configuration comes back.
if [ "$want_code" = true ] && [ "$want_config" != true ] && [ -d /etc/puppetlabs/r10k ]; then
  tar -C / -cf - etc/puppetlabs/r10k | tar -C "$stage/files" -xpf - || fail 'copying the r10k configuration failed'
fi

serial_after=''
[ -f "$cadir/serial" ] && serial_after=$(tr -d '[:space:]' < "$cadir/serial")
serial_moved=false
[ "$serial_before" != "$serial_after" ] && serial_moved=true

# Recorded before they are started again, which empties the list.
stopped_json=$(printf '%s\n' "${stopped[@]}" | json_lines)
start_services

# eyaml keys live where each environment's hiera.yaml says, usually outside
# the tree. Warn for any that exists on the host and the archive does not
# hold; a hiera.yaml naming a key the host never had (a feature branch, a
# template) is not a gap in the backup.
if [ -d "$codedir/environments" ]; then
  for hiera in "$codedir"/environments/*/hiera.yaml; do
    [ -f "$hiera" ] || continue
    envdir=$(dirname "$hiera")
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      case "$key" in
        /*) ;;
        *) key="$envdir/$key" ;;
      esac
      [ -e "$key" ] || continue
      [ -e "$stage/files$key" ] || warn "eyaml private key $key (named in $hiera) is not in the archive; add it to extra_paths"
    done < <(sed -n 's/^[[:space:]]*pkcs7_private_key:[[:space:]]*["'"'"']\{0,1\}\([^"'"'"']*\)["'"'"']\{0,1\}[[:space:]]*$/\1/p' "$hiera" | sort -u)
  done
fi

# --- topology ----------------------------------------------------------------------------
topology_script=''
if [ -n "${PT__installdir:-}" ] && [ -f "$PT__installdir/ovadm/tasks/topology.sh" ]; then
  topology_script="$PT__installdir/ovadm/tasks/topology.sh"
elif [ -f "$(dirname "$0")/topology.sh" ]; then
  topology_script="$(dirname "$0")/topology.sh"
fi
if [ -n "$topology_script" ] && bash "$topology_script" > "$stage/ovadm/topology.json" 2>/dev/null; then
  :
else
  printf 'null\n' > "$stage/ovadm/topology.json"
  warn 'topology.sh is not available; the archive holds no topology'
fi

# --- manifest -------------------------------------------------------------------------------
os_id=$(sed -n 's/^ID=//p' /etc/os-release 2>/dev/null | tr -d '"')
os_version=$(sed -n 's/^VERSION_ID=//p' /etc/os-release 2>/dev/null | tr -d '"')

packages=''
for pkg in openvox-agent openvox-server openvoxdb openvoxdb-termini postgresql-server postgresql; do
  packages="${packages:+$packages,
}    $(json_str "$pkg"): $(json_str "$(installed_version "$pkg")")"
done

# Gems the operator added: to the server's JRuby (the package's own are
# vendored elsewhere) and to the agent Ruby, r10k and hiera-eyaml among them.
# Only gems no package owns are recorded, so an agent upgrade between the
# backup and a restore does not turn the package's own gems into "missing"
# ones. Read from the specification files, so no JVM starts.
gem_names() {
  local d specs=()
  for d in "$@"; do
    [ -d "$d" ] || continue
    while IFS= read -r f; do specs+=("$f"); done < <(find "$d" -maxdepth 1 -name '*.gemspec' | sort)
  done
  [ "${#specs[@]}" -gt 0 ] || return 0
  if command -v rpm >/dev/null 2>&1 && rpm -q rpm >/dev/null 2>&1; then
    rpm -qf "${specs[@]}" 2>&1 | sed -n 's/^file \(.*\.gemspec\) is not owned by any package$/\1/p'
  elif command -v dpkg-query >/dev/null 2>&1; then
    dpkg-query -S "${specs[@]}" 2>&1 | sed -n 's/^dpkg-query: no path found matching pattern \(.*\.gemspec\)$/\1/p'
  else
    printf '%s\n' "${specs[@]}"
  fi | sed 's|.*/||; s/\.gemspec$//' | sort -u
  return 0
}
server_gems=$(gem_names /opt/puppetlabs/server/data/puppetserver/jruby-gems/specifications | json_lines)
agent_gems=$(gem_names /opt/puppetlabs/puppet/lib/ruby/gems/*/specifications | json_lines)

environments=''
if [ -d "$codedir/environments" ]; then
  for envdir in "$codedir"/environments/*/; do
    [ -d "$envdir" ] || continue
    env=$(basename "$envdir")
    sig=''; deployed=''
    if [ -f "$envdir.r10k-deploy.json" ]; then
      sig=$(sed -n 's/.*"signature"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$envdir.r10k-deploy.json" | head -n 1)
      deployed=$(sed -n 's/.*"finished_at"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$envdir.r10k-deploy.json" | head -n 1)
    fi
    environments="${environments:+$environments,
}    $(json_str "$env"): {\"signature\": $(json_str "$sig"), \"deployed\": $(json_str "$deployed")}"
  done
fi

# OpenVoxDB's schema version, over the connection OpenVoxDB itself uses, so
# a restore can tell whether a hand-taken dump matches. Best effort.
schema_version=''
if [ -r "$database_ini" ] && command -v psql >/dev/null 2>&1; then
  subname=$(ini_get "$database_ini" subname)
  db_user=$(ini_get "$database_ini" username)
  db_pass=$(ini_get "$database_ini" password)
  if [ -n "$subname" ]; then
    rest=${subname#//}; db_name=${rest##*/}; hostport=${rest%%/*}
    db_host=${hostport%%:*}; db_port=${hostport#*:}
    [ "$db_port" = "$hostport" ] && db_port=5432
    schema_version=$(PGPASSWORD="$db_pass" PGCONNECT_TIMEOUT=5 psql -h "$db_host" -p "$db_port" -U "${db_user:-puppetdb}" -d "$db_name" -AtX \
      -c 'select max(version) from schema_migrations' 2>/dev/null || true)
  fi
fi

# Whether the openvox_server module manages this host, which decides what a
# restore of configuration can and cannot roll back.
module_in_catalog=false
catalog="/opt/puppetlabs/puppet/cache/client_data/catalog/${certname}.json"
[ -f "$catalog" ] && grep -q '"Class\[Openvox_server\]"' "$catalog" && module_in_catalog=true
module_version=''
module_meta="$codedir/environments/$agent_environment/modules/openvox_server/metadata.json"
[ -f "$module_meta" ] && module_version=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$module_meta" | head -n 1)

file_count=$(find "$stage/files" -type f | wc -l | tr -d ' ')
extra_json=$(printf '%s\n' "${extra_list[@]}" | json_lines)

# One key per line at the top level and inside packages, which is what
# backup_verify reads it with.
cat > "$stage/ovadm/manifest.json" <<MANIFEST
{
  "format": 1,
  "name": $(json_str "$name"),
  "created": $(json_str "$created"),
  "certname": $(json_str "$certname"),
  "hostname": $(json_str "$hostname_fqdn"),
  "os": {"id": $(json_str "$os_id"), "version": $(json_str "$os_version")},
  "ovadm_version": $(json_str "$ovadm_version"),
  "backup": {"ca": $want_ca, "config": $want_config, "code": $want_code, "include_code_tree": $take_tree, "extra_paths": $extra_json, "stop_services": $stop_services, "services_stopped": $stopped_json},
  "paths": {"cadir": $(json_str "$cadir"), "ssldir": $(json_str "$ssldir"), "codedir": $(json_str "$codedir")},
  "ca": {"serial_before": $(json_str "$serial_before"), "serial_after": $(json_str "$serial_after"), "serial_moved": $serial_moved},
  "packages": {
$packages
  },
  "gems": {"puppetserver": $server_gems, "agent": $agent_gems},
  "environments": {
$environments
  },
  "openvoxdb": {"database_ini": $(json_str "$database_ini"), "schema_version": $(json_str "$schema_version")},
  "openvox_server_module": {"in_last_catalog": $module_in_catalog, "version": $(json_str "$module_version")},
  "files": $file_count
}
MANIFEST

(cd "$stage" && find files ovadm -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum > "$work/SHA256SUMS" && mv "$work/SHA256SUMS" ovadm/SHA256SUMS)

# --- archive -------------------------------------------------------------------------------
if [ -n "$age_recipient" ]; then
  archive="$destination/$name.tar.gz.age"
  tar -C "$work" -czf - "$name" | age -r "$age_recipient" -o "$work/out" || fail 'writing the archive failed'
else
  archive="$destination/$name.tar.gz"
  tar -C "$work" -czf "$work/out" "$name" || fail 'writing the archive failed'
fi
chmod 0600 "$work/out"
mv "$work/out" "$archive"
size=$(stat -c %s "$archive")

warnings_json=$(printf '%s\n' "${warnings[@]}" | json_lines)
printf '{"status":"created","archive":%s,"size_bytes":%s,"files":%s,"certname":%s,"created":%s,"ca_serial_moved":%s,"services_stopped":%s,"warnings":%s}\n' \
  "$(json_str "$archive")" "$size" "$file_count" "$(json_str "$certname")" "$(json_str "$created")" \
  "$serial_moved" "$stopped_json" "$warnings_json"
