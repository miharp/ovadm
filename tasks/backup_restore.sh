#!/bin/bash
# Put the files of an archive that backup_create wrote back on the host it
# came from. Checks first: every checksum, the certname, the openvox-server
# version, and, when the CA is in scope, that the CA on the host has not
# signed certificates the archive does not know. Then stops the services
# that are running, extracts the items in scope over the live tree with
# owners and modes as archived, and starts the services again. Package
# manager leftovers (*.rpmnew, *.rpmsave, *.dpkg-dist, *.dpkg-old) are never
# put back. With dry_run, reports what would change and touches nothing.
set -euo pipefail
umask 077

export PATH="/opt/puppetlabs/bin:$PATH"

archive="${PT_archive:-}"
scope="${PT_scope:-}"
force="${PT_force:-false}"
dry_run="${PT_dry_run:-false}"
age_identity="${PT_age_identity:-}"

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
cleanup() { start_services; rm -rf "$work"; }
trap cleanup EXIT

# --- unpack and check the archive --------------------------------------------
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
else
  if [ "$want_ca" = true ]; then add_include "$cadir"; add_include "$ssldir"; add_include "$puppetdb_ssl"; fi
  [ "$want_code" = true ] && add_include "$codedir"
fi
if [ "$want_extra" = true ]; then
  while IFS= read -r p; do add_include "$p"; done <<< "$extra_paths"
fi
[ "${#includes[@]}" -gt 0 ] || fail 'none of the paths in scope are in the archive'

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
ca_json='null'
if [ "$want_ca" = true ]; then
  live_differs=false; signed_after=()
  if [ -f "$cadir/ca_crt.pem" ] && [ -f "$top/files${cadir}/ca_crt.pem" ]; then
    # sha256sum rather than cmp: diffutils is not in every base image.
    if [ "$(sha256sum < "$cadir/ca_crt.pem")" != "$(sha256sum < "$top/files${cadir}/ca_crt.pem")" ]; then
      live_differs=true
      warn "the CA on this host is not the one in the archive; it is replaced by the restore"
    elif [ -f "$cadir/inventory.txt" ] && [ -f "$top/files${cadir}/inventory.txt" ]; then
      # inventory.txt lines: 0xSERIAL not_before not_after /CN=name
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        signed_after+=("$(printf '%s' "$line" | sed -n 's|.*/CN=||p') (serial ${line%% *})")
      done < <(grep -vxF -f "$top/files${cadir}/inventory.txt" "$cadir/inventory.txt" || true)
      if [ "${#signed_after[@]}" -gt 0 ]; then
        if [ "$force" != true ]; then
          fail "the CA has signed ${#signed_after[@]} certificate(s) since the backup: $(printf '%s, ' "${signed_after[@]}" | sed 's/, $//'). The restored CA would not know them. Pass force=true to restore anyway, then clean and re-sign them"
        fi
        warn "the restored CA does not know ${#signed_after[@]} certificate(s) signed since the backup: $(printf '%s, ' "${signed_after[@]}" | sed 's/, $//')"
      fi
    fi
  elif [ ! -f "$cadir/ca_crt.pem" ]; then
    warn "no CA on this host; the archive's is put in place"
  fi
  ca_json=$(printf '{"live_ca_differs":%s,"signed_after_backup":%s}' "$live_differs" "$(printf '%s\n' "${signed_after[@]}" | json_lines)")
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
report() {
  printf '{"status":"%s","archive":%s,"certname":%s,"scope":%s,"in_scope":%s,"changed":%s,"missing":%s,"unchanged":%s,"ca":%s,"services_stopped":%s,"missing_gems":{"puppetserver":%s,"agent":%s},"warnings":%s}\n' \
    "$1" "$(json_str "$archive")" "$(json_str "$certname")" "$scope_json" "$in_scope" \
    "$(printf '%s\n' "${changed[@]}" | json_lines)" "$(printf '%s\n' "${missing[@]}" | json_lines)" "$unchanged" \
    "$ca_json" "$2" "$gems_server" "$gems_agent" "$(printf '%s\n' "${warnings[@]}" | json_lines)"
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
for svc in puppetserver puppetdb; do
  if service_running "$svc"; then
    systemctl stop "$svc" >&2 || fail "could not stop $svc"
    stopped+=("$svc")
  fi
done
stopped_json=$(printf '%s\n' "${stopped[@]}" | json_lines)

tar_excludes=()
for e in "${excludes[@]}"; do tar_excludes+=("--exclude=$e"); done
if ! tar -C "$top/files" --anchored "${tar_excludes[@]}" \
    --exclude='*.rpmnew' --exclude='*.rpmsave' --exclude='*.dpkg-dist' --exclude='*.dpkg-old' \
    -cf - "${includes[@]}" | tar -C / -xpf -; then
  fail 'putting the files back failed; the services are started again'
fi
start_services

report restored "$stopped_json"
