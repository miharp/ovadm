#!/bin/bash
set -euo pipefail

version="${PT_version:-}"
termini_only="${PT_termini_only:-false}"

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
  if [ "$termini_only" = 'true' ]; then
    if [ -n "$version" ]; then
      apt-get install -y "openvoxdb-termini=${version}*" >&2
    else
      apt-get install -y openvoxdb-termini >&2
    fi
  else
    if [ -n "$version" ]; then
      apt-get install -y "openvoxdb=${version}*" "openvoxdb-termini=${version}*" >&2
    else
      apt-get install -y openvoxdb openvoxdb-termini >&2
    fi
  fi
  installed=$(dpkg -l openvoxdb 2>/dev/null | awk '/^ii/{print $3}' || echo 'not_installed')
elif [ "$os_family" = 'RedHat' ]; then
  if [ "$termini_only" = 'true' ]; then
    if [ -n "$version" ]; then
      yum install -y "openvoxdb-termini-${version}" >&2
    else
      yum install -y openvoxdb-termini >&2
    fi
  else
    if [ -n "$version" ]; then
      yum install -y "openvoxdb-${version}" "openvoxdb-termini-${version}" >&2
    else
      yum install -y openvoxdb openvoxdb-termini >&2
    fi
  fi
  installed=$(rpm -q --queryformat '%{VERSION}-%{RELEASE}' openvoxdb 2>/dev/null || echo 'not_installed')
else
  printf '{"status":"fail","error":"Unsupported OS family"}\n'
  exit 1
fi

printf '{"status":"success","version":"%s"}\n' "$installed"
