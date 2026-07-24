#!/bin/bash
set -euo pipefail

version="${PT_version:-}"
package_url="${PT_package_url:-}"

os_family=''
if [ -f /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    ubuntu|debian)
      os_family='Debian' ;;
    rhel|centos|rocky|almalinux|ol|fedora)
      os_family='RedHat' ;;
    *)
      case "${ID_LIKE:-}" in
        *debian*)        os_family='Debian' ;;
        *rhel*|*fedora*) os_family='RedHat' ;;
      esac ;;
  esac
fi

# codavox names its packages by Go architecture (amd64 / arm64), not uname's.
case "$(uname -m)" in
  x86_64)        arch='amd64' ;;
  aarch64|arm64) arch='arm64' ;;
  *)
    printf '{"status":"fail","error":"unsupported architecture %s"}\n' "$(uname -m)"
    exit 1 ;;
esac

url="$package_url"

if [ "$os_family" = 'Debian' ]; then
  export DEBIAN_FRONTEND=noninteractive
  if [ -z "$url" ]; then
    [ -n "$version" ] || { printf '{"status":"fail","error":"version or package_url required"}\n'; exit 1; }
    url="https://github.com/miharp/codavox/releases/download/v${version}/codavox_${version}_linux_${arch}.deb"
  fi
  case "$url" in
    http*://*)
      # apt cannot install from a URL, so fetch it first.
      tmp="$(mktemp --suffix=.deb)"
      curl -fsSL -o "$tmp" "$url"
      apt-get install -y "$tmp" >&2
      rm -f "$tmp" ;;
    *)
      apt-get install -y "$url" >&2 ;;
  esac
elif [ "$os_family" = 'RedHat' ]; then
  if [ -z "$url" ]; then
    [ -n "$version" ] || { printf '{"status":"fail","error":"version or package_url required"}\n'; exit 1; }
    url="https://github.com/miharp/codavox/releases/download/v${version}/codavox_${version}_linux_${arch}.rpm"
  fi
  # yum/dnf install from a URL or a local path directly.
  yum install -y "$url" >&2
else
  printf '{"status":"fail","error":"unsupported OS family"}\n'
  exit 1
fi

installed="$(codavox version 2>/dev/null || echo unknown)"
printf '{"status":"success","version":"%s"}\n' "$installed"
