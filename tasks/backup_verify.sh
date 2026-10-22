#!/bin/bash
# Check an archive that backup_create wrote: it unpacks, holds a manifest and
# a checksum list, every file matches its checksum, and (unless check_host is
# off) the archive is from this host and its package versions match. Problems
# are reported in the result with status "failed"; only an archive that cannot
# be read at all fails the task.
set -euo pipefail
umask 077

export PATH="/opt/puppetlabs/bin:$PATH"

archive="${PT_archive:-}"
check_host="${PT_check_host:-true}"
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
  printf '{"status":"failed","archive":%s,"_error":{"kind":"ovadm/backup","msg":%s}}\n' "$(json_str "$archive")" "$(json_str "$1")"
  exit 1
}
installed_version() {
  local pkg="$1" v
  v=$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || true)
  if [ -z "$v" ]; then
    v=$(rpm -q --queryformat '%{VERSION}-%{RELEASE}' "$pkg" 2>/dev/null) || v=''
  fi
  printf '%s' "$v"
}
# A top-level string value of the manifest: one key per line, two-space indent.
manifest_get() {
  sed -n "s/^  \"$1\": \"\([^\"]*\)\",\{0,1\}\$/\1/p" "$manifest" | head -n 1
}

[ -n "$archive" ] || fail 'archive is required'
[ -f "$archive" ] || fail "$archive does not exist"
# A rebuilt host may lack tar: removing the agent package can take it along.
command -v tar >/dev/null 2>&1 || fail 'tar is not installed on this host; install it first'

work=$(mktemp -d "$(dirname "$archive")/.verify.XXXXXX" 2>/dev/null) || work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

case "$archive" in
  *.age)
    command -v age >/dev/null 2>&1 || fail 'the archive is encrypted and age is not installed'
    [ -n "$age_identity" ] || fail 'the archive is encrypted; age_identity (an identity file) is required to read it'
    [ -f "$age_identity" ] || fail "age identity $age_identity does not exist"
    age -d -i "$age_identity" "$archive" | tar -xzf - -C "$work" || fail 'the archive could not be decrypted and unpacked'
    ;;
  *)
    tar -xzf "$archive" -C "$work" || fail 'the archive could not be unpacked'
    ;;
esac

top=$(find "$work" -mindepth 1 -maxdepth 1 -type d | head -n 1)
[ -n "$top" ] || fail 'the archive holds no directory'
name=$(basename "$top")
manifest="$top/ovadm/manifest.json"
sums="$top/ovadm/SHA256SUMS"

problems=()
warnings=()
[ -f "$manifest" ] || problems+=('no ovadm/manifest.json in the archive')
[ -f "$sums" ] || problems+=('no ovadm/SHA256SUMS in the archive')

checked=0
failed_files=()
if [ -f "$sums" ]; then
  checked=$(grep -c . "$sums" || true)
  while IFS= read -r line; do
    failed_files+=("${line%: *}")
  done < <(cd "$top" && sha256sum --quiet -c ovadm/SHA256SUMS 2>/dev/null | grep ': FAILED' || true)
  if [ "${#failed_files[@]}" -gt 0 ]; then
    problems+=("${#failed_files[@]} file(s) do not match their checksum: ${failed_files[*]}")
  fi
  # Files in the archive that the list does not cover.
  unlisted=$(cd "$top" && find files ovadm -type f ! -path ovadm/SHA256SUMS | LC_ALL=C sort | comm -23 - <(sed 's/^[0-9a-f]*  //' ovadm/SHA256SUMS | LC_ALL=C sort) || true)
  if [ -n "$unlisted" ]; then
    problems+=("file(s) in the archive without a checksum: $(printf '%s' "$unlisted" | tr '\n' ' ')")
  fi
fi

created=''; certname=''; manifest_files=''
if [ -f "$manifest" ]; then
  created=$(manifest_get created)
  certname=$(manifest_get certname)
  manifest_files=$(sed -n 's/^  "files": \([0-9]*\),\{0,1\}$/\1/p' "$manifest" | head -n 1)
  [ -n "$certname" ] || problems+=('the manifest names no certname')
  actual_files=$(find "$top/files" -type f 2>/dev/null | wc -l | tr -d ' ')
  if [ -n "$manifest_files" ] && [ "$manifest_files" != "$actual_files" ]; then
    problems+=("the manifest counts $manifest_files file(s), the archive holds $actual_files")
  fi
fi

host_json='null'
if [ "$check_host" = true ] && [ -f "$manifest" ]; then
  if command -v puppet >/dev/null 2>&1; then
    host_certname=$(puppet config print certname --section server 2>/dev/null || true)
  fi
  host_certname=${host_certname:-$(hostname -f 2>/dev/null || hostname)}
  certname_matches=false
  if [ "$host_certname" = "$certname" ]; then
    certname_matches=true
  else
    problems+=("the archive is from $certname, this host is $host_certname")
  fi
  pkg_json=''
  while IFS= read -r line; do
    pkg=$(printf '%s' "$line" | sed -n 's/^    "\([^"]*\)": .*/\1/p')
    [ -n "$pkg" ] || continue
    archived=$(printf '%s' "$line" | sed -n 's/^    "[^"]*": "\([^"]*\)".*/\1/p')
    here=$(installed_version "$pkg")
    pkg_json="${pkg_json:+$pkg_json,}$(json_str "$pkg"):{\"archive\":$(json_str "$archived"),\"host\":$(json_str "$here")}"
    if [ "$archived" != "$here" ]; then
      warnings+=("$pkg is ${archived:-not installed} in the archive and ${here:-not installed} on this host")
    fi
  done < <(sed -n '/^  "packages": {$/,/^  },\{0,1\}$/p' "$manifest")
  host_json=$(printf '{"certname":%s,"certname_matches":%s,"packages":{%s}}' "$(json_str "$host_certname")" "$certname_matches" "$pkg_json")
fi

status=ok
[ "${#problems[@]}" -eq 0 ] || status=failed

printf '{"status":"%s","archive":%s,"name":%s,"created":%s,"certname":%s,"files":%s,"checksums":{"checked":%s,"failed":%s},"host":%s,"problems":%s,"warnings":%s}\n' \
  "$status" "$(json_str "$archive")" "$(json_str "$name")" "$(json_str "$created")" "$(json_str "$certname")" \
  "${manifest_files:-0}" "$checked" "$(printf '%s\n' "${failed_files[@]}" | json_lines)" \
  "$host_json" "$(printf '%s\n' "${problems[@]}" | json_lines)" "$(printf '%s\n' "${warnings[@]}" | json_lines)"
