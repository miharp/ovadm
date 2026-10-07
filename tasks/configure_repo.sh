#!/bin/bash
set -euo pipefail

OVOX_MAJOR="${PT_ovox_major:-8}"
APT_BASE_URL="${PT_apt_base_url:-https://apt.voxpupuli.org}"
YUM_BASE_URL="${PT_yum_base_url:-https://yum.voxpupuli.org}"
APT_BASE_URL="${APT_BASE_URL%/}"
YUM_BASE_URL="${YUM_BASE_URL%/}"

# The release package's repository file names the public repository whatever
# URL the package came from, so point it at the base URL given: a mirror of
# apt.voxpupuli.org or yum.voxpupuli.org, with the same layout. With the
# default base URL this changes nothing.
point_repository_at() {
  local file=$1 public=$2 base=$3 escaped
  [ -f "$file" ] || return 0
  escaped=$(printf '%s' "$base" | sed -e 's/[\\&#]/\\&/g')
  sed -i "s#${public//./\\.}#${escaped}#g" "$file"
}

os_id=''
os_version=''
os_family=''

if [ -f /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  os_id="${ID:-}"
  os_version="${VERSION_ID:-}"
  case "$os_id" in
    ubuntu|debian)
      os_family='Debian' ;;
    rhel|centos|rocky|almalinux|ol|fedora)
      os_family='RedHat' ;;
    *)
      case "${ID_LIKE:-}" in
        *debian*)        os_family='Debian'  ;;
        *rhel*|*fedora*) os_family='RedHat'  ;;
        *)               os_family='Unknown' ;;
      esac ;;
  esac
fi

url=''
repository_file=''
keep="openvox${OVOX_MAJOR}-release"
stale=()

if [ "$os_family" = 'Debian' ]; then
  pkg_name="openvox${OVOX_MAJOR}-release-${os_id}${os_version}.deb"
  url="${APT_BASE_URL}/${pkg_name}"
  tmpfile=$(mktemp "/tmp/${pkg_name}.XXXXX")
  curl -fsSL -o "$tmpfile" "$url"

  # Release packages for other OpenVox majors, and Puppet's, would keep the
  # host on their repositories. The OpenVox ones also all ship
  # /etc/apt/preferences.d/openvox-release.pref, so dpkg refuses the new
  # package until the old one is gone. Purge, so a removed package's conffiles
  # don't linger. The new package is downloaded first, so a bad URL leaves the
  # old repository in place.
  mapfile -t stale < <(dpkg-query -W -f='${Package} ${Status}\n' 2>/dev/null |
    awk -v keep="$keep" '$1 ~ /^(openvox|puppet)[0-9]+-release$/ && $1 != keep && $NF != "not-installed" {print $1}')
  if [ "${#stale[@]}" -gt 0 ]; then
    dpkg --purge "${stale[@]}" >&2
  fi

  # The .list is a conffile. Keep a copy edited on the node, as install_server
  # does: with no terminal, dpkg's question about it would fail the run.
  dpkg -i --force-confdef --force-confold "$tmpfile" >&2
  rm -f "$tmpfile"
  repository_file="/etc/apt/sources.list.d/openvox${OVOX_MAJOR}-release.list"
  point_repository_at "$repository_file" 'https://apt.voxpupuli.org' "$APT_BASE_URL"
  apt-get update -qq >&2
elif [ "$os_family" = 'RedHat' ]; then
  el_major="${os_version%%.*}"
  pkg_name="openvox${OVOX_MAJOR}-release-el-${el_major}.noarch.rpm"
  url="${YUM_BASE_URL}/${pkg_name}"
  rpm -Uvh --replacepkgs "$url" >&2
  # The package does not mark the .repo as a config file, so reinstalling it
  # puts the public URL back; point it at the base URL again each time.
  repository_file="/etc/yum.repos.d/openvox${OVOX_MAJOR}-release.repo"
  point_repository_at "$repository_file" 'https://yum.voxpupuli.org' "$YUM_BASE_URL"

  # On EL the release packages install side by side, so the old ones can go
  # once the new one is in.
  mapfile -t stale < <(rpm -qa --queryformat '%{NAME}\n' |
    grep -E '^(openvox|puppet)[0-9]+-release$' | grep -vx "$keep" || true)
  if [ "${#stale[@]}" -gt 0 ]; then
    rpm -e "${stale[@]}" >&2
  fi

  yum makecache -q >&2 || true
else
  printf '{"status":"fail","error":"Unsupported OS family: %s"}\n' "$os_family"
  exit 1
fi

removed=''
for pkg in "${stale[@]}"; do
  removed="${removed:+$removed,}\"$pkg\""
done

repository=''
if [ -f "$repository_file" ]; then
  repository=$(grep -m1 -o -E 'https?://[^ ]+' "$repository_file" || true)
fi

printf '{"status":"success","repo_url":"%s","repository_file":"%s","repository":"%s","removed":[%s]}\n' \
  "$url" "$repository_file" "$repository" "$removed"
