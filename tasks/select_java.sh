#!/bin/bash
set -euo pipefail

# The openvox-server package pulls in a JRE but leaves the java alternative
# alone. A host upgraded from an older major, such as Puppet Server 7 on Java 11,
# keeps its old default and the service fails at startup with
# UnsupportedClassVersionError. Point the alternative at a Java the installed
# server supports, when the default is not one already.

server_version=$(dpkg -l openvox-server 2>/dev/null | awk '/^ii/{print $3}' | head -1 || true)
if [ -z "$server_version" ]; then
  server_version=$(rpm -q --queryformat '%{VERSION}' openvox-server 2>/dev/null) || server_version=''
fi

if [ -z "$server_version" ]; then
  printf '{"status":"fail","error":"openvox-server is not installed"}\n'
  exit 1
fi

server_major="${server_version%%.*}"
if [ "$server_major" -ge 9 ]; then
  supported='21 25'
else
  supported='17 21'
fi

java_major() {
  "$1" -version 2>&1 | awk -F'"' '/version/{print $2; exit}' | cut -d. -f1
}

is_supported() {
  case " $supported " in
    *" $1 "*) return 0 ;;
    *)        return 1 ;;
  esac
}

current=''
current_major=''
if command -v java >/dev/null 2>&1; then
  current=$(readlink -f "$(command -v java)")
  current_major=$(java_major "$current")
fi

if [ -n "$current_major" ] && is_supported "$current_major"; then
  printf '{"status":"unchanged","java":"%s","version":"%s"}\n' "$current" "$current_major"
  exit 0
fi

alternatives_cmd=$(command -v update-alternatives || command -v alternatives || true)
if [ -z "$alternatives_cmd" ]; then
  printf '{"status":"fail","error":"neither update-alternatives nor alternatives is available"}\n'
  exit 1
fi

# --display lists each candidate as "<path> - priority N" (Debian) or
# "<path> - family F priority N" (EL). Take the newest supported one.
best=''
best_major=0
while read -r candidate; do
  major=$(java_major "$candidate")
  if is_supported "$major" && [ "$major" -gt "$best_major" ]; then
    best="$candidate"
    best_major="$major"
  fi
done < <("$alternatives_cmd" --display java 2>/dev/null | awk '$2 == "-" {print $1}')

if [ -z "$best" ]; then
  printf '{"status":"fail","error":"openvox-server %s needs Java %s, and none is installed as a java alternative (default is %s)"}\n' \
    "$server_version" "${supported// / or }" "${current_major:-none}"
  exit 1
fi

"$alternatives_cmd" --set java "$best" >&2

printf '{"status":"changed","java":"%s","version":"%s","previous":"%s"}\n' \
  "$best" "$best_major" "$current_major"
