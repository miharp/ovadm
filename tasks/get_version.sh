#!/bin/bash
set -euo pipefail

version=$(dpkg -l openvox-server 2>/dev/null | awk '/^ii/{print $3}' | head -1 || true)

if [ -z "$version" ]; then
  version=$(rpm -q --queryformat '%{VERSION}-%{RELEASE}' openvox-server 2>/dev/null || true)
fi

if [ -z "$version" ]; then
  version='not_installed'
fi

printf '{"version":"%s"}\n' "$version"
