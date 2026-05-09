#!/bin/bash
set -euo pipefail

OVOX_MAJOR="${PT_ovox_major:-8}"

os_id=''
os_version=''
os_family=''

if [ -f /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  os_id="${ID:-}"
  os_version="${VERSION_ID:-}"
  case "$os_id" in
    ubuntu|debian)
      os_family='Debian' ;;
    rhel|centos|rocky|almalinux|ol|fedora)
      os_family='RedHat' ;;
    *)
      case "${ID_LIKE:-}" in
        *debian*)        os_family='Debian'  ;;
        *rhel*|*fedora*) os_family='RedHat'  ;;
        *)               os_family='Unknown' ;;
      esac ;;
  esac
fi

url=''

if [ "$os_family" = 'Debian' ]; then
  pkg_name="openvox${OVOX_MAJOR}-release-${os_id}${os_version}.deb"
  url="https://apt.voxpupuli.org/${pkg_name}"
  tmpfile=$(mktemp "/tmp/${pkg_name}.XXXXX")
  curl -fsSL -o "$tmpfile" "$url"
  dpkg -i "$tmpfile" >&2
  rm -f "$tmpfile"
  apt-get update -qq >&2
elif [ "$os_family" = 'RedHat' ]; then
  el_major="${os_version%%.*}"
  pkg_name="openvox${OVOX_MAJOR}-release-el-${el_major}.noarch.rpm"
  url="https://yum.voxpupuli.org/${pkg_name}"
  rpm -Uvh "$url" >&2
  yum makecache -q >&2 || true
else
  printf '{"status":"fail","error":"Unsupported OS family: %s"}\n' "$os_family"
  exit 1
fi

printf '{"status":"success","repo_url":"%s"}\n' "$url"
