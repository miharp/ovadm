#!/bin/bash
set -euo pipefail

os_name=''
os_release=''
os_family=''
arch=$(uname -m)

if [ -f /etc/os-release ]; then
  # shellcheck source=/dev/null
  . /etc/os-release
  os_name="${NAME:-}"
  os_release="${VERSION_ID:-}"

  case "${ID:-}" in
    ubuntu|debian)         os_family='Debian' ;;
    rhel|centos|rocky|almalinux|ol|fedora) os_family='RedHat' ;;
    *)
      case "${ID_LIKE:-}" in
        *debian*) os_family='Debian' ;;
        *rhel*|*fedora*) os_family='RedHat' ;;
        *) os_family='Unknown' ;;
      esac
      ;;
  esac
fi

printf '{"os_family":"%s","os_name":"%s","os_release":"%s","arch":"%s"}\n' \
  "$os_family" "$os_name" "$os_release" "$arch"
