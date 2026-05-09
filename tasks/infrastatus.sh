#!/bin/bash
set -euo pipefail

version=$(dpkg -l openvox-server 2>/dev/null | awk '/^ii/{print $3}' | head -1 || true)
if [ -z "$version" ]; then
  version=$(rpm -q --queryformat '%{VERSION}-%{RELEASE}' openvox-server 2>/dev/null || true)
fi
if [ -z "$version" ]; then
  version='not_installed'
fi

if systemctl is-active --quiet puppetserver 2>/dev/null; then
  service='running'
else
  service='stopped'
fi

if ss -tlnp 2>/dev/null | grep -q ':8140 '; then
  port_8140='listening'
else
  port_8140='not_listening'
fi

printf '{"version":"%s","service":"%s","port_8140":"%s"}\n' \
  "$version" "$service" "$port_8140"
