#!/bin/bash
# Put the files of an archive that backup_create wrote back on the host it
# came from. Checks first: every checksum, the certname, the openvox-server
# version, and, when the CA is in scope, that the CA on the host has not
# signed or revoked certificates the archive does not know. Then stops the
# services that are running, extracts the items in scope over the live tree
# with owners and modes as archived, and starts the services again, with the
# agent disabled meanwhile so no scheduled run lands in the middle. Package
# manager leftovers (*.rpmnew, *.rpmsave, *.dpkg-dist, *.dpkg-old) are never
# put back. With dry_run, reports what would change and touches nothing.
set -euo pipefail
umask 077

export PATH="/opt/puppetlabs/bin:$PATH"

archive="${PT_archive:-}"
scope="${PT_scope:-}"
exclude="${PT_exclude:-}"
force="${PT_force:-false}"
dry_run="${PT_dry_run:-false}"
age_identity="${PT_age_identity:-}"
strip_openvoxdb_settings="${PT_strip_openvoxdb_settings:-false}"

json_str() {
  if [ -z "${1:-}" ]; then
    printf 'null'
  else
    printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  fi
}
json_lines() {
  local out='' line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    out="${out:+$out,}$(json_str "$line")"
  done
  printf '[%s]' "$out"
}
fail() {
  printf '{"status":"failed","archive":%s,"_error":{"kind":"ovadm/restore","msg":%s}}\n' "$(json_str "$archive")" "$(json_str "$1")"
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
# Top-level string value of the manifest (one key per line, two-space indent).
manifest_get() { sed -n "s/^  \"$1\": \"\([^\"]*\)\",\{0,1\}\$/\1/p" "$manifest" | head -n 1; }
# A quoted string value inside a one-line object on a top-level line: manifest_sub LINEKEY KEY
manifest_sub() { sed -n "s/^  \"$1\": .*\"$2\": \"\([^\"]*\)\".*/\1/p" "$manifest" | head -n 1; }
# A JSON array of strings on a top-level line, as lines: manifest_list LINEKEY KEY
manifest_list() {
  sed -n "s/^  \"$1\": .*\"$2\": \[\([^]]*\)\].*/\1/p" "$manifest" | head -n 1 \
    | tr ',' '\n' | sed 's/^[[:space:]]*"//; s/"[[:space:]]*$//' | grep . || true
}
regex_escape() { printf '%s' "$1" | sed 's/[.[\*^$|?+(){}]/\\&/g'; }

[ -n "$archive" ] || fail 'archive is required'
[ -f "$archive" ] || fail "$archive does not exist"
command -v tar >/dev/null 2>&1 || fail 'tar is not installed on this host; install it first'
[ "$(id -u)" -eq 0 ] || fail 'must run as root'

work=$(mktemp -d "$(dirname "$archive")/.restore.XXXXXX" 2>/dev/null) || work=$(mktemp -d)
stopped=()
start_services() {
  local svc
  for svc in "${stopped[@]}"; do
    systemctl start "$svc" >&2 || warn "could not start $svc"
  done
  stopped=()
}
# --- the agent -------------------------------------------------------------------------
# A scheduled agent run in the middle of the copy would apply the site's code over files still being put back. Disable the agent
# for the duration, as an operator would by hand, and wait for a run already
# under way to finish. An agent the operator had disabled before stays
# disabled afterwards.
agent_disabled_here=false
agent_lock_wait=300
disable_agent() {
  local disabled_lock run_lock waited=0
  command -v puppet >/dev/null 2>&1 || return 0
  disabled_lock=$(puppet config print agent_disabled_lockfile --section agent 2>/dev/null || true)
  run_lock=$(puppet config print agent_catalog_run_lockfile --section agent 2>/dev/null || true)
  if [ -n "$disabled_lock" ] && [ ! -e "$disabled_lock" ]; then
    if puppet agent --disable "$1" >/dev/null 2>&1; then
      agent_disabled_here=true
    else
      warn 'could not disable the agent; a scheduled run may land during the copy'
    fi
  fi
  [ -n "$run_lock" ] || return 0
  while [ -e "$run_lock" ] && [ "$waited" -lt "$agent_lock_wait" ]; do
    sleep 5
    waited=$((waited + 5))
  done
  if [ -e "$run_lock" ]; then
    fail "an agent run (pid $(cat "$run_lock" 2>/dev/null || echo '?')) has not finished after ${agent_lock_wait} s; wait for it, then run this again"
  fi
  return 0
}
enable_agent() {
  [ "$agent_disabled_here" = true ] || return 0
  puppet agent --enable >/dev/null 2>&1 || warn 'could not enable the agent again; run puppet agent --enable'
}
cleanup() { start_services; enable_agent; rm -rf "$work"; }
trap cleanup EXIT

# --- unpack and check the archive --------------------------------------------
# The whole archive is unpacked beside it first, so its uncompressed size has
# to be free there; gzip keeps that size in its trailer. An encrypted archive
# gives no cheap size, so the check is skipped for it.
human() { numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || printf '%s bytes' "$1"; }
case "$archive" in
  *.gz)
    if command -v df >/dev/null 2>&1 && command -v gzip >/dev/null 2>&1; then
      needed=$(gzip -l "$archive" 2>/dev/null | awk 'NR==2 {print $2}')
      read -r avail mount < <(df -P -B1 "$work" 2>/dev/null | awk 'NR==2 {print $4, $6}') || true
      if [ -n "${needed:-}" ] && [ -n "${avail:-}" ] && [ "$avail" -lt "$needed" ]; then
        fail "not enough space under $(dirname "$work") to unpack the archive: $(human "$needed") needed, $(human "$avail") free on $mount"
      fi
    fi
    ;;
esac
case "$archive" in
  *.age)
    command -v age >/dev/null 2>&1 || fail 'the archive is encrypted and age is not installed'
    [ -n "$age_identity" ] || fail 'the archive is encrypted; age_identity (an identity file) is required to read it'
    [ -f "$age_identity" ] || fail "age identity $age_identity does not exist"
    age -d -i "$age_identity" "$archive" | tar -xzf - -C "$work" || fail 'the archive could not be decrypted and unpacked'
    ;;
  *) tar -xzf "$archive" -C "$work" || fail 'the archive could not be unpacked' ;;
esac
top=$(find "$work" -mindepth 1 -maxdepth 1 -type d | head -n 1)
[ -n "$top" ] || fail 'the archive holds no directory'
manifest="$top/ovadm/manifest.json"
sums="$top/ovadm/SHA256SUMS"
[ -f "$manifest" ] || fail 'no ovadm/manifest.json in the archive'
[ -f "$sums" ] || fail 'no ovadm/SHA256SUMS in the archive'
bad=$(cd "$top" && sha256sum --quiet -c ovadm/SHA256SUMS 2>/dev/null | grep ': FAILED' | sed 's/: FAILED.*//' || true)
[ -z "$bad" ] || fail "the archive does not match its checksums: $(printf '%s' "$bad" | tr '\n' ' ')"

# --- the archive against this host ------------------------------------------------
certname=$(manifest_get certname)
[ -n "$certname" ] || fail 'the manifest names no certname'
if command -v puppet >/dev/null 2>&1; then
  host_certname=$(puppet config print certname --section server 2>/dev/null || true)
fi
host_certname=${host_certname:-$(hostname -f 2>/dev/null || hostname)}
if [ "$host_certname" != "$certname" ]; then
  [ "$force" = true ] || fail "the archive is from $certname, this host is $host_certname; pass force=true to restore it here anyway"
  warn "restoring an archive from $certname onto $host_certname"
fi

archived_server=$(sed -n 's/^    "openvox-server": "\([^"]*\)".*/\1/p' "$manifest" | head -n 1)
archived_agent=$(sed -n 's/^    "openvox-agent": "\([^"]*\)".*/\1/p' "$manifest" | head -n 1)
host_server=$(installed_version openvox-server)
if [ -n "$archived_server" ] && [ -z "$host_server" ]; then
  fail "openvox-server is not installed; install it first, then restore: bolt plan run ovadm::install server_host=<this host> ovox_server_version=${archived_server%%-*}${archived_agent:+ ovox_version=${archived_agent%%-*}}"
fi
if [ -n "$archived_server" ] && [ "$archived_server" != "$host_server" ]; then
  [ "$force" = true ] || fail "the archive is from openvox-server $archived_server, this host runs $host_server; pass force=true to restore anyway"
  warn "openvox-server is $archived_server in the archive and $host_server on this host"
fi

# --- scope ---------------------------------------------------------------------------------
has_ca=$(sed -n 's/^  "backup": {"ca": \([a-z]*\),.*/\1/p' "$manifest")
has_config=$(sed -n 's/^  "backup": .*"config": \([a-z]*\),.*/\1/p' "$manifest")
has_code=$(sed -n 's/^  "backup": .*"code": \([a-z]*\),.*/\1/p' "$manifest")
extra_paths=$(manifest_list backup extra_paths)
cadir=$(manifest_sub paths cadir); cadir=${cadir:-/etc/puppetlabs/puppetserver/ca}
ssldir=$(manifest_sub paths ssldir); ssldir=${ssldir:-/etc/puppetlabs/puppet/ssl}
codedir=$(manifest_sub paths codedir); codedir=${codedir:-/etc/puppetlabs/code}
puppetdb_ssl='/etc/puppetlabs/puppetdb/ssl'
etc_root='/etc/puppetlabs'

if [ -z "$scope" ]; then
  [ "$has_ca" = true ] && scope="ca"
  [ "$has_config" = true ] && scope="${scope:+$scope,}config"
  [ "$has_code" = true ] && scope="${scope:+$scope,}code"
  [ -n "$extra_paths" ] && scope="${scope:+$scope,}extra"
fi
want_ca=false; want_config=false; want_code=false; want_extra=false
IFS=',' read -r -a scope_items <<< "$scope"
for item in "${scope_items[@]}"; do
  case "$item" in
    ca)     [ "$has_ca" = true ] || fail 'the archive holds no ca'; want_ca=true ;;
    config) [ "$has_config" = true ] || fail 'the archive holds no config'; want_config=true ;;
    code)   [ "$has_code" = true ] || fail 'the archive holds no code'; want_code=true ;;
    extra)  [ -n "$extra_paths" ] || fail 'the archive holds no extra paths'; want_extra=true ;;
    '') ;;
    *) fail "unknown scope item '$item' (ca, config, code, extra)" ;;
  esac
done
[ "$want_ca" = true ] || [ "$want_config" = true ] || [ "$want_code" = true ] || [ "$want_extra" = true ] || fail 'nothing in scope'

# Paths relative to the archive's files/ directory, and the excludes.
includes=()
excludes=()
add_include() { [ -e "$top/files/${1#/}" ] && includes+=("${1#/}"); return 0; }
add_exclude() { excludes+=("${1#/}"); }
if [ "$want_config" = true ]; then
  add_include "$etc_root"
  for f in /etc/sysconfig/puppetserver /etc/sysconfig/puppetdb /etc/default/puppetserver /etc/default/puppetdb; do add_include "$f"; done
  [ "$want_code" = true ] || add_exclude "$codedir"
  if [ "$want_ca" != true ]; then add_exclude "$cadir"; add_exclude "$ssldir"; add_exclude "$puppetdb_ssl"; fi
  # The static catalog commands conf.d names, taken with the configuration
  # because a restored conf.d points at them.
  while IFS= read -r p; do [ -n "$p" ] && add_include "$p"; done <<< "$(manifest_list backup static_catalog_scripts)"
else
  if [ "$want_ca" = true ]; then add_include "$cadir"; add_include "$ssldir"; add_include "$puppetdb_ssl"; fi
  if [ "$want_code" = true ]; then add_include "$codedir"; add_include /etc/puppetlabs/r10k; fi
fi
if [ "$want_extra" = true ]; then
  while IFS= read -r p; do add_include "$p"; done <<< "$extra_paths"
fi
[ "${#includes[@]}" -gt 0 ] || fail 'none of the paths in scope are in the archive'
# Paths left out of this pass, as ovadm::restore does with the OpenVoxDB
# wiring on a rebuilt host.
excluded=()
if [ -n "$exclude" ]; then
  IFS=',' read -r -a exclude_list <<< "$exclude"
  for p in "${exclude_list[@]}"; do
    [ -n "$p" ] || continue
    case "$p" in /*) ;; *) fail "exclude path '$p' is not absolute" ;; esac
    add_exclude "$p"
    excluded+=("$p")
  done
fi

# --- what would change ---------------------------------------------------------------------
inc_re=$(printf '%s|' "${includes[@]}" | sed 's/|$//'); inc_re=$(regex_escape "$inc_re" | sed 's/\\|/|/g')
exc_re=''
[ "${#excludes[@]}" -gt 0 ] && exc_re=$(printf '%s|' "${excludes[@]}" | sed 's/|$//') && exc_re=$(regex_escape "$exc_re" | sed 's/\\|/|/g')
grep -E "^[0-9a-f]+  files/($inc_re)(/|$)" "$sums" \
  | { if [ -n "$exc_re" ]; then grep -vE "^[0-9a-f]+  files/($exc_re)(/|$)"; else cat; fi; } \
  | grep -vE '\.(rpmnew|rpmsave|dpkg-dist|dpkg-old)$' \
  | sed 's|  files/|  /|' > "$work/scope.sums" || true
in_scope=$(grep -c . "$work/scope.sums" || true)
changed=(); missing=(); unchanged=0
if [ "$in_scope" -gt 0 ]; then
  while IFS= read -r line; do
    case "$line" in
      *': OK') unchanged=$((unchanged + 1)) ;;
      *': FAILED open or read') missing+=("${line%: FAILED open or read}") ;;
      *': FAILED') changed+=("${line%: FAILED}") ;;
    esac
  done < <(sha256sum -c "$work/scope.sums" 2>/dev/null || true)
fi

# --- owners this host does not have ---------------------------------------------------
# tar put the archive's user and group names back by name where the host
# has them and by number where it does not: a rebuilt host before the
# package that creates the user (puppetdb, until the site's code installs
# OpenVoxDB) gets the files under the old uid.
unknown=''
for inc in "${includes[@]}"; do
  unknown="$unknown
$(find "$top/files/$inc" -printf '%u:%g %p\n' 2>/dev/null | awk '$1 ~ /^[0-9]+:/ || $1 ~ /:[0-9]+$/' | sed "s| $top/files| |")"
done
unknown=$(printf '%s\n' "$unknown" | grep . || true)
if [ -n "$unknown" ]; then
  ids=$(printf '%s\n' "$unknown" | awk '{print $1}' | sort -u | tr '\n' ' ' | sed 's/ $//')
  count=$(printf '%s\n' "$unknown" | wc -l | tr -d ' ')
  examples=$(printf '%s\n' "$unknown" | awk '{print $2}' | head -n 3 | tr '\n' ' ' | sed 's/ $//')
  warn "$count file(s) belong to uid:gid $ids, which no user on this host has (for example $examples); they are put back under those numbers. Install the package that creates the user, then chown them, or let the site's code do it"
fi

# --- the CA on the host against the one in the archive -------------------------------------
# Serials as the CRL and inventory.txt write them, made comparable: lower
# case, no 0x, no leading zeros.
norm_serial() { printf '%s' "$1" | tr 'A-F' 'a-f' | sed 's/^0x//; s/^0*//; s/^$/0/'; }
# crl_serials FILE: the revoked serials of a CRL, one per line; fails when
# no openssl is available to read it.
crl_serials() {
  local ssl s
  ssl=$(command -v openssl 2>/dev/null || true)
  [ -n "$ssl" ] || { [ -x /opt/puppetlabs/puppet/bin/openssl ] && ssl=/opt/puppetlabs/puppet/bin/openssl; }
  [ -n "$ssl" ] || return 1
  "$ssl" crl -in "$1" -noout -text 2>/dev/null | sed -n 's/^[[:space:]]*Serial Number:[[:space:]]*//p' \
    | while IFS= read -r s; do norm_serial "$s"; printf '\n'; done
}
# inventory_name INVENTORY SERIAL: the certname the inventory has for a serial
inventory_name() {
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [ "$(norm_serial "${line%% *}")" = "$2" ]; then printf '%s' "$line" | sed -n 's|.*/CN=||p'; return 0; fi
  done < "$1"
  return 1
}
ca_json='null'
if [ "$want_ca" = true ]; then
  live_differs=false; signed_after=(); revoked_after=(); pdb_unknown=(); pdb_json='null'
  if [ -f "$cadir/ca_crt.pem" ] && [ -f "$top/files${cadir}/ca_crt.pem" ]; then
    # sha256sum rather than cmp: diffutils is not in every base image.
    if [ "$(sha256sum < "$cadir/ca_crt.pem")" != "$(sha256sum < "$top/files${cadir}/ca_crt.pem")" ]; then
      live_differs=true
      warn "the CA on this host is not the one in the archive; it is replaced by the restore"
    else
      if [ -f "$cadir/inventory.txt" ] && [ -f "$top/files${cadir}/inventory.txt" ]; then
        # inventory.txt lines: 0xSERIAL not_before not_after /CN=name
        while IFS= read -r line; do
          [ -n "$line" ] || continue
          signed_after+=("$(printf '%s' "$line" | sed -n 's|.*/CN=||p') (serial ${line%% *})")
        done < <(grep -vxF -f "$top/files${cadir}/inventory.txt" "$cadir/inventory.txt" || true)
        if [ "${#signed_after[@]}" -gt 0 ]; then
          names=$(printf '%s, ' "${signed_after[@]}" | sed 's/, $//')
          # The restored CA counts serials on from the archive's, so these
          # serials come round again: a ca clean on them would put a serial
          # the next certificate gets on the CRL.
          if [ "$force" != true ]; then
            fail "the CA has signed ${#signed_after[@]} certificate(s) since the backup: $names. The restored CA would not know them. Pass force=true to restore anyway, then delete signed/<name>.pem for each on this host and enrol the host again; do not use puppetserver ca clean on them, which would revoke a serial the restored CA reissues"
          fi
          warn "the restored CA does not know ${#signed_after[@]} certificate(s) signed since the backup: $names. Delete signed/<name>.pem for each and enrol the host again; do not use puppetserver ca clean on them, which would revoke a serial the restored CA reissues"
        fi
      fi
      # The archive's CRL is the one that comes back, so a certificate
      # revoked since the backup is valid again unless revoked once more.
      if [ -f "$cadir/ca_crl.pem" ] && [ -f "$top/files${cadir}/ca_crl.pem" ]; then
        if archived_revoked=$(crl_serials "$top/files${cadir}/ca_crl.pem") && live_revoked=$(crl_serials "$cadir/ca_crl.pem"); then
          while IFS= read -r serial; do
            [ -n "$serial" ] || continue
            grep -qxF "$serial" <<< "$archived_revoked" && continue
            cn=$(inventory_name "$cadir/inventory.txt" "$serial" 2>/dev/null || true)
            revoked_after+=("${cn:-unknown} (serial 0x$serial)")
          done <<< "$live_revoked"
          if [ "${#revoked_after[@]}" -gt 0 ]; then
            names=$(printf '%s, ' "${revoked_after[@]}" | sed 's/, $//')
            if [ "$force" != true ]; then
              fail "the CA has revoked ${#revoked_after[@]} certificate(s) since the backup: $names. The restored CA would consider them valid again. Pass force=true to restore anyway, then revoke them again with puppetserver ca revoke --certname <name>"
            fi
            warn "the restored CA considers ${#revoked_after[@]} certificate(s) revoked since the backup valid again: $names. Revoke them again with puppetserver ca revoke --certname <name>"
          fi
        else
          warn 'openssl is not available, so the revocation lists were not compared; a certificate revoked since the backup is valid again after the restore'
        fi
      fi
    fi
  elif [ ! -f "$cadir/ca_crt.pem" ]; then
    # The record of who enrolled since the backup went with the directory.
    # OpenVoxDB's node list is the next best one: every node that has
    # checked in is there.
    pdb_port=$(sed -n 's/^[[:space:]]*port[[:space:]]*=[[:space:]]*//p' /etc/puppetlabs/puppetdb/conf.d/jetty.ini 2>/dev/null | head -1 | tr -d '[:space:]' || true)
    pdb_port=${pdb_port:-8080}
    if command -v curl >/dev/null 2>&1 && nodes=$(curl -sf --max-time 5 "http://localhost:$pdb_port/pdb/query/v4/nodes" 2>/dev/null); then
      known=$(sed -n 's|.*/CN=||p' "$top/files${cadir}/inventory.txt" 2>/dev/null | sort -u)
      while IFS= read -r n; do
        [ -n "$n" ] || continue
        grep -qxF "$n" <<< "$known" || pdb_unknown+=("$n")
      done < <(printf '%s' "$nodes" | grep -o '"certname"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*:[[:space:]]*"//; s/"$//' | sort -u)
      pdb_json=$(printf '%s\n' "${pdb_unknown[@]}" | json_lines)
      if [ "${#pdb_unknown[@]}" -gt 0 ]; then
        warn "no CA on this host; the archive's is put in place. OpenVoxDB lists ${#pdb_unknown[@]} node(s) the archive's inventory does not: $(printf '%s, ' "${pdb_unknown[@]}" | sed 's/, $//'). If they enrolled since the backup, delete any signed/<name>.pem of theirs that survived and enrol them again; do not use puppetserver ca clean on them. Hosts that have not checked in since the backup are not on this list"
      else
        warn "no CA on this host; the archive's is put in place. OpenVoxDB lists no node the archive's inventory lacks"
      fi
    else
      warn "no CA on this host; the archive's is put in place. OpenVoxDB did not answer on localhost:$pdb_port, so the hosts enrolled since the backup could not be listed; compare its node list with the archive's inventory.txt"
    fi
  fi
  ca_json=$(printf '{"live_ca_differs":%s,"signed_after_backup":%s,"revoked_after_backup":%s,"openvoxdb_nodes_unknown_to_archive":%s}' \
    "$live_differs" "$(printf '%s\n' "${signed_after[@]}" | json_lines)" "$(printf '%s\n' "${revoked_after[@]}" | json_lines)" "$pdb_json")
fi

# --- missing gems ------------------------------------------------------------------------
# missing_gems LISTKEY DIR...: gems the manifest lists under LISTKEY that no
# specification directory given has.
missing_gems() {
  local listkey="$1" d names=''
  shift
  for d in "$@"; do
    [ -d "$d" ] && names="$names
$(find "$d" -maxdepth 1 -name '*.gemspec' -printf '%f\n' 2>/dev/null | sed 's/\.gemspec$//')"
  done
  manifest_list gems "$listkey" | while IFS= read -r g; do
    grep -qxF "$g" <<< "$names" || printf '%s\n' "$g"
  done
}
gems_server=$(missing_gems puppetserver /opt/puppetlabs/server/data/puppetserver/jruby-gems/specifications | json_lines)
gems_agent=$(missing_gems agent /opt/puppetlabs/puppet/lib/ruby/gems/*/specifications | json_lines)

scope_json=$(printf '%s\n' "${scope_items[@]}" | json_lines)
excluded_json=$(printf '%s\n' "${excluded[@]}" | json_lines)
stripped=()
report() {
  printf '{"status":"%s","archive":%s,"certname":%s,"scope":%s,"excluded":%s,"in_scope":%s,"changed":%s,"missing":%s,"unchanged":%s,"ca":%s,"services_stopped":%s,"agent_disabled":%s,"settings_stripped":%s,"missing_gems":{"puppetserver":%s,"agent":%s},"warnings":%s}\n' \
    "$1" "$(json_str "$archive")" "$(json_str "$certname")" "$scope_json" "$excluded_json" "$in_scope" \
    "$(printf '%s\n' "${changed[@]}" | json_lines)" "$(printf '%s\n' "${missing[@]}" | json_lines)" "$unchanged" \
    "$ca_json" "$2" "$agent_disabled_here" "$(printf '%s\n' "${stripped[@]}" | json_lines)" "$gems_server" "$gems_agent" "$(printf '%s\n' "${warnings[@]}" | json_lines)"
}

if [ "$dry_run" = true ]; then
  report dry_run '[]'
  exit 0
fi

# --- restore ---------------------------------------------------------------------------------
# A service that is starting counts as running: puppetserver crashes when
# its CA directory disappears under it, systemd starts it again, and the
# restart takes a while, during which the files must not change under it.
service_running() {
  command -v systemctl >/dev/null 2>&1 || return 1
  case "$(systemctl is-active "$1" 2>/dev/null)" in
    active|activating|reloading|deactivating) return 0 ;;
  esac
  return 1
}
disable_agent "ovadm restore of $(basename "$archive") in progress"
for svc in puppetserver puppetdb; do
  if service_running "$svc"; then
    systemctl stop "$svc" >&2 || fail "could not stop $svc"
    stopped+=("$svc")
  fi
done
stopped_json=$(printf '%s\n' "${stopped[@]}" | json_lines)

tar_excludes=()
for e in "${excludes[@]}"; do tar_excludes+=("--exclude=$e"); done
# Everything tar takes keeps its archived owner and mode. A directory it has
# to make up on the way to a path, one the host does not have yet (codavox's
# under /opt/puppetlabs, say, before its package is back), gets 0755 as the
# host's own would, not the 0700 this script's umask gives: a root-only
# parent shuts the services out of what is restored beneath it.
if ! tar -C "$top/files" --anchored "${tar_excludes[@]}" \
    --exclude='*.rpmnew' --exclude='*.rpmsave' --exclude='*.dpkg-dist' --exclude='*.dpkg-old' \
    -cf - "${includes[@]}" | (umask 022 && tar -C / -xpf -); then
  fail 'putting the files back failed; the services are started again'
fi
# On a rebuilt host the settings that point the server at OpenVoxDB come
# out of the restored puppet.conf until OpenVoxDB exists again; the rest of
# the file (certname, server, environment, dns_alt_names) stays, since the
# agent run that brings OpenVoxDB back needs it. A later pass puts the file
# back whole.
if [ "$strip_openvoxdb_settings" = true ] && [ -f /etc/puppetlabs/puppet/puppet.conf ]; then
  for setting in storeconfigs storeconfigs_backend reports; do
    if grep -qE "^[[:space:]]*${setting}[[:space:]]*=" /etc/puppetlabs/puppet/puppet.conf; then
      sed -i -E "/^[[:space:]]*${setting}[[:space:]]*=/d" /etc/puppetlabs/puppet/puppet.conf
      stripped+=("$setting")
    fi
  done
fi
start_services

report restored "$stopped_json"
