#!/bin/bash
set -euo pipefail

# Each check returns a JSON fragment; we assemble them at the end.
pass=true

# --- OS family ---
os_family='Unknown'
if [ -f /etc/os-release ]; then
  # shellcheck source=/dev/null
  . /etc/os-release
  case "${ID:-}" in
    ubuntu|debian)                             os_family='Debian' ;;
    rhel|centos|rocky|almalinux|ol|fedora)     os_family='RedHat' ;;
    *)
      case "${ID_LIKE:-}" in
        *debian*)        os_family='Debian'  ;;
        *rhel*|*fedora*) os_family='RedHat'  ;;
      esac
      ;;
  esac
fi

if [ "$os_family" = 'Unknown' ]; then
  os_check='{"check":"os_family","status":"fail","detail":"Unrecognised OS — expected Debian or RedHat family"}'
  pass=false
else
  os_check=$(printf '{"check":"os_family","status":"pass","detail":"%s"}' "$os_family")
fi

# --- Java ---
java_version=''
java_status='warn'
java_detail='java not found; will be installed as a dependency of openvox-server'

if command -v java >/dev/null 2>&1; then
  java_version=$(java -version 2>&1 | awk -F'"' '/version/{print $2}' | head -1)
  major=$(echo "$java_version" | cut -d. -f1)
  if [ "$major" = '17' ] || [ "$major" = '21' ]; then
    java_status='pass'
    java_detail="java $java_version"
  else
    java_status='fail'
    java_detail="java $java_version found but OpenVox requires 17 or 21"
    pass=false
  fi
fi

java_check=$(printf '{"check":"java","status":"%s","detail":"%s"}' "$java_status" "$java_detail")

# --- Port 8140 available (not already bound) ---
port_status='pass'
port_detail='port 8140 is free'

if command -v ss >/dev/null 2>&1; then
  if ss -tlnH 'sport = :8140' 2>/dev/null | grep -q 8140; then
    port_status='pass'
    port_detail='puppetserver is already listening on 8140'
  fi
elif command -v netstat >/dev/null 2>&1; then
  if netstat -tlnp 2>/dev/null | grep -q ':8140'; then
    port_status='pass'
    port_detail='puppetserver is already listening on 8140'
  fi
fi

port_check=$(printf '{"check":"port_8140","status":"%s","detail":"%s"}' "$port_status" "$port_detail")

# --- NTP / time sync ---
ntp_status='fail'
ntp_detail='time sync status unknown'

if command -v timedatectl >/dev/null 2>&1; then
  if timedatectl show --property=NTPSynchronized --value 2>/dev/null | grep -q '^yes$'; then
    ntp_status='pass'
    ntp_detail='NTP synchronised'
  else
    ntp_status='warn'
    ntp_detail='NTP not synchronised — verify time sync before production use'
  fi
elif command -v chronyc >/dev/null 2>&1; then
  if chronyc tracking 2>/dev/null | grep -q 'Reference ID'; then
    ntp_status='pass'
    ntp_detail='chrony tracking active'
  else
    ntp_status='warn'
    ntp_detail='chrony not synchronised — verify time sync before production use'
  fi
else
  ntp_status='warn'
  ntp_detail='cannot determine time sync status (no timedatectl or chronyc)'
fi

ntp_check=$(printf '{"check":"ntp","status":"%s","detail":"%s"}' "$ntp_status" "$ntp_detail")

# --- Assemble output ---
overall=$([ "$pass" = 'true' ] && echo 'pass' || echo 'fail')

printf '{"status":"%s","checks":[%s,%s,%s,%s]}\n' \
  "$overall" "$os_check" "$java_check" "$port_check" "$ntp_check"
