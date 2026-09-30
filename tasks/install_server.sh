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
        *debian*)        os_family='Debian'  ;;
        *rhel*|*fedora*) os_family='RedHat'  ;;
      esac ;;
  esac
fi

# When openvox-server replaces puppetserver, its install hook sees a fresh
# install and resets vardir, logdir, rundir, pidfile and codedir in [server] of
# puppet.conf to the package defaults. Keep a copy to put back afterwards. An
# existing copy is from a run that failed partway; it holds the original.
PUPPET_CONF='/etc/puppetlabs/puppet/puppet.conf'
conf_backup="${PUPPET_CONF}.ovadm-pre-openvox"
if [ -f "$PUPPET_CONF" ] && [ ! -f "$conf_backup" ] &&
   { dpkg -l puppetserver 2>/dev/null | grep -q '^ii' || rpm -q puppetserver >/dev/null 2>&1; }; then
  cp -p "$PUPPET_CONF" "$conf_backup"
fi

if [ "$os_family" = 'Debian' ]; then
  export DEBIAN_FRONTEND=noninteractive
  # Keep conffiles the operator edited (e.g. JAVA_ARGS in
  # /etc/default/puppetserver); the package's version lands as .dpkg-dist.
  # Without this dpkg prompts, reads EOF from Bolt's non-TTY stdin, and leaves
  # openvox-server unpacked but not configured.
  apt_opts=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
  if [ -n "$package_url" ]; then
    apt-get install "${apt_opts[@]}" "$package_url" >&2
  elif [ -n "$version" ]; then
    apt-get install "${apt_opts[@]}" "openvox-server=${version}*" >&2
  else
    apt-get install "${apt_opts[@]}" openvox-server >&2
  fi
  installed=$(dpkg -l openvox-server 2>/dev/null | awk '/^ii/{print $3}' || echo 'unknown')
elif [ "$os_family" = 'RedHat' ]; then
  if [ -n "$package_url" ]; then
    yum install -y "$package_url" >&2
  elif [ -n "$version" ]; then
    yum install -y "openvox-server-${version}" >&2
  else
    yum install -y openvox-server >&2
  fi
  installed=$(rpm -q --queryformat '%{VERSION}-%{RELEASE}' openvox-server 2>/dev/null || echo 'unknown')
else
  printf '{"status":"fail","error":"Unsupported OS family"}\n'
  exit 1
fi

restored_puppet_conf=false
if [ -f "$conf_backup" ]; then
  if ! cmp -s "$conf_backup" "$PUPPET_CONF"; then
    cp -p "$conf_backup" "$PUPPET_CONF"
    restored_puppet_conf=true
  fi
  rm -f "$conf_backup"
fi

printf '{"status":"success","version":"%s","restored_puppet_conf":%s}\n' "$installed" "$restored_puppet_conf"
