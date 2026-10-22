#!/bin/bash
# Install one package at a given version from the repositories the host has,
# with dnf or apt-get. Used by ovadm::restore for the pieces a rebuilt host
# needs before its own code can run, such as openvoxdb-termini.
set -euo pipefail

name="${PT_name:-}"
version="${PT_version:-}"

json_str() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }
fail() {
  printf '{"status":"failed","package":%s,"_error":{"kind":"ovadm/install-package","msg":%s}}\n' "$(json_str "$name")" "$(json_str "$1")"
  exit 1
}
installed_version() {
  local v
  v=$(dpkg-query -W -f='${Version}' "$name" 2>/dev/null || true)
  if [ -z "$v" ]; then
    v=$(rpm -q --queryformat '%{VERSION}-%{RELEASE}' "$name" 2>/dev/null) || v=''
  fi
  printf '%s' "$v"
}

[ -n "$name" ] || fail 'name is required'
have=$(installed_version)
if [ -n "$have" ] && { [ -z "$version" ] || [ "$have" = "$version" ]; }; then
  printf '{"status":"already_installed","package":%s,"version":%s}\n' "$(json_str "$name")" "$(json_str "$have")"
  exit 0
fi

if command -v dnf >/dev/null 2>&1; then
  spec="$name${version:+-$version}"
  dnf install -y -q "$spec" >&2 || fail "dnf could not install $spec"
elif command -v apt-get >/dev/null 2>&1; then
  spec="$name${version:+=$version}"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$spec" >&2 || fail "apt-get could not install $spec"
else
  fail 'neither dnf nor apt-get found'
fi

now=$(installed_version)
[ -n "$now" ] || fail "$name is still not installed"
printf '{"status":"installed","package":%s,"version":%s,"previous":%s}\n' \
  "$(json_str "$name")" "$(json_str "$now")" "$( [ -n "$have" ] && json_str "$have" || printf null )"
