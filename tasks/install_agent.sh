#!/bin/bash
set -euo pipefail

version="${PT_version:-}"

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
        *debian*)        os_family='Debian'  ;;
        *rhel*|*fedora*) os_family='RedHat'  ;;
      esac ;;
  esac
fi

if [ "$os_family" = 'Debian' ]; then
  export DEBIAN_FRONTEND=noninteractive
  if [ -n "$version" ]; then
    apt-get install -y "openvox-agent=${version}*" >&2
  else
    apt-get install -y openvox-agent >&2
  fi
  installed=$(dpkg -l openvox-agent 2>/dev/null | awk '/^ii/{print $3}' | head -1 || true)
elif [ "$os_family" = 'RedHat' ]; then
  if [ -n "$version" ]; then
    yum install -y "openvox-agent-${version}" >&2
  else
    yum install -y openvox-agent >&2
  fi
  installed=$(rpm -q --queryformat '%{VERSION}-%{RELEASE}' openvox-agent 2>/dev/null || true)
else
  printf '{"status":"fail","error":"Unsupported OS family"}\n'
  exit 1
fi

if [ -z "$installed" ]; then
  installed='unknown'
fi

printf '{"status":"success","version":"%s"}\n' "$installed"
