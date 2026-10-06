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
# OpenVox Server 8 runs the system java, which must be 17 or 21. OpenVox
# Server 9 packages ship a launcher that the service runs instead: it picks
# the first of Java 25 and 21 installed, or JAVA_BIN from the defaults file,
# and ignores the java alternative (see select_java). So where the launcher is
# installed, check the Java it runs; where 9 or later is about to be
# installed, the system java does not matter, since the package brings
# Java 21.
java_version=''
java_status='warn'
java_detail='java not found; will be installed as a dependency of openvox-server'
launcher=/opt/puppetlabs/server/apps/puppetserver/bin/java

java_major() {
  "$1" -version 2>&1 | awk -F'"' '/version/{print $2; exit}' | cut -d. -f1
}

if [ -x "$launcher" ]; then
  java_defaults=/etc/default/puppetserver
  [ -r "$java_defaults" ] || java_defaults=/etc/sysconfig/puppetserver
  # shellcheck source=/dev/null
  if launcher_java=$(set +eu -a; [ -r "$java_defaults" ] && . "$java_defaults"; set +a; "$launcher" 2>/dev/null); then
    launcher_major=$(java_major "$launcher_java" || true)
    if [ "${launcher_major:-0}" -ge 21 ] 2>/dev/null; then
      java_status='pass'
      java_detail="openvox-server runs Java ${launcher_major} (${launcher_java}) through its launcher"
    else
      java_status='fail'
      java_detail="openvox-server runs ${launcher_java} (Java ${launcher_major:-unknown}), set as JAVA_BIN in ${java_defaults}; it needs Java 21 or 25"
      pass=false
    fi
  else
    java_status='fail'
    java_detail="openvox-server picks its Java through ${launcher}, which found no Java 21 or 25 installed"
    pass=false
  fi
elif [ "${PT_ovox_major:-0}" -ge 9 ]; then
  java_status='pass'
  java_detail="OpenVox Server ${PT_ovox_major} installs Java 21 as a dependency and picks its Java through a launcher, not the system java"
elif command -v java >/dev/null 2>&1; then
  java_version=$(java -version 2>&1 | awk -F'"' '/version/{print $2}' | head -1)
  major=$(echo "$java_version" | cut -d. -f1)
  if [ "$major" = '17' ] || [ "$major" = '21' ]; then
    java_status='pass'
    java_detail="java $java_version"
  elif [ "${PT_upgrade:-false}" = 'true' ]; then
    # ovadm::upgrade runs select_java after the package install, which points
    # java at the JRE the package pulls in.
    java_status='warn'
    java_detail="java $java_version is the default; the upgrade will select the Java that openvox-server installs"
  else
    java_status='fail'
    java_detail="java $java_version found but OpenVox Server 8 requires 17 or 21"
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

# --- Host firewall: is 8140 allowed in? ---
# Warn-only. The install succeeds either way — readiness is probed on localhost
# — so this is the one place an operator hears that agents and compilers will
# be refused. Raw nftables/iptables rulesets are not inspected.
fw_status='pass'
fw_detail='no active firewalld or ufw'

if command -v firewall-cmd >/dev/null 2>&1 && [ "$(firewall-cmd --state 2>/dev/null)" = 'running' ]; then
  # firewalld ships a predefined service for 8140, named "puppetmaster".
  if firewall-cmd --query-port=8140/tcp >/dev/null 2>&1 ||
     firewall-cmd --query-service=puppetmaster >/dev/null 2>&1; then
    fw_detail='firewalld allows 8140/tcp in the default zone'
  else
    fw_status='warn'
    fw_detail='firewalld is running and its default zone does not allow 8140/tcp; agents and compilers will be refused — firewall-cmd --permanent --add-port=8140/tcp && firewall-cmd --reload'
  fi
elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  if ufw status 2>/dev/null | grep -Eq '^8140(/tcp)?[[:space:]]+ALLOW'; then
    fw_detail='ufw allows 8140/tcp'
  else
    fw_status='warn'
    fw_detail='ufw is active and has no rule allowing 8140/tcp; agents and compilers will be refused — ufw allow 8140/tcp'
  fi
fi

fw_check=$(printf '{"check":"firewall","status":"%s","detail":"%s"}' "$fw_status" "$fw_detail")

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

# --- Memory for the heap ---
# OpenVox Server refuses to start when MemTotal is less than 1.1 times its
# maximum heap (validate-memory-requirements! in master_core.clj). Without
# this check an install on a smaller host fails only when
# wait_until_service_ready times out. The heap is -Xmx in JAVA_ARGS, read as
# the service reads it, or the packaged 2 GB where OpenVox Server is not
# installed yet.
mem_status='pass'
mem_detail='cannot read MemTotal from /proc/meminfo'
mem_kb=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo 2>/dev/null || true)

if [ -n "$mem_kb" ]; then
  heap_kb=2097152
  heap_source='the packaged 2048 MB heap'
  defaults=''
  for f in /etc/sysconfig/puppetserver /etc/default/puppetserver; do
    if [ -r "$f" ]; then
      defaults=$f
      break
    fi
  done

  if [ -n "$defaults" ]; then
    # shellcheck source=/dev/null
    java_args=$(set +eu; . "$defaults" >/dev/null 2>&1; printf '%s' "${JAVA_ARGS:-}")
    # The JVM uses the last -Xmx it is given.
    xmx=$(printf '%s\n' "$java_args" | tr ' ' '\n' | grep -E '^-Xmx[0-9]+[kKmMgG]?$' | tail -1 || true)
    if [ -n "$xmx" ]; then
      size=${xmx#-Xmx}
      case "$size" in
        *[kK]) heap_kb=${size%?} ;;
        *[mM]) heap_kb=$(( ${size%?} * 1024 )) ;;
        *[gG]) heap_kb=$(( ${size%?} * 1048576 )) ;;
        *)     heap_kb=$(( size / 1024 )) ;;
      esac
      heap_source="the $(( heap_kb / 1024 )) MB heap (${xmx}) in ${defaults}"
    else
      # Without -Xmx the JVM takes a quarter of the memory, which always fits.
      heap_kb=0
    fi
  fi

  mem_mb=$(( mem_kb / 1024 ))
  need_mb=$(( (heap_kb * 11 + 10239) / 10240 ))
  if [ "$heap_kb" -eq 0 ]; then
    mem_detail="${mem_mb} MB of memory; JAVA_ARGS in ${defaults} sets no -Xmx, so the JVM sizes the heap to fit"
  elif [ $(( mem_kb * 10 )) -lt $(( heap_kb * 11 )) ]; then
    mem_status='fail'
    if [ -n "$defaults" ] && [ -n "${xmx:-}" ]; then
      remedy="lower -Xms and -Xmx in JAVA_ARGS in ${defaults}, or use a host with more memory"
    else
      remedy="use a host with at least ${need_mb} MB of memory"
    fi
    mem_detail="${mem_mb} MB of memory, but OpenVox Server refuses to start with ${heap_source} on less than ${need_mb} MB (1.1 times the heap); ${remedy}"
    pass=false
  else
    mem_detail="${mem_mb} MB of memory, enough for ${heap_source} (OpenVox Server needs ${need_mb} MB)"
  fi
fi

mem_check=$(printf '{"check":"memory","status":"%s","detail":"%s"}' "$mem_status" "$mem_detail")

# --- Assemble output ---
overall=$([ "$pass" = 'true' ] && echo 'pass' || echo 'fail')

printf '{"status":"%s","checks":[%s,%s,%s,%s,%s,%s]}\n' \
  "$overall" "$os_check" "$java_check" "$port_check" "$fw_check" "$ntp_check" "$mem_check"
