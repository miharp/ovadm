#!/bin/bash
set -euo pipefail

# puppetserver is checked too, so a host still on Puppet Server can be upgraded
# to OpenVox. The two cannot be installed together.
version=''
package=''
for pkg in openvox-server puppetserver; do
  version=$(dpkg -l "$pkg" 2>/dev/null | awk '/^ii/{print $3}' | head -1 || true)

  if [ -z "$version" ]; then
    version=$(rpm -q --queryformat '%{VERSION}-%{RELEASE}' "$pkg" 2>/dev/null) || version=''
  fi

  if [ -n "$version" ]; then
    package="$pkg"
    break
  fi
done

if [ -z "$version" ]; then
  printf '{"version":"not_installed","package":null}\n'
else
  printf '{"version":"%s","package":"%s"}\n' "$version" "$package"
fi
