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
        *debian*)        os_family='Debian' ;;
        *rhel*|*fedora*) os_family='RedHat' ;;
      esac ;;
  esac
fi

# The public key of the harpworks package repository, pinned here rather than
# fetched at install time so the trust anchor is reviewed like any other
# change. The repository signs its metadata, not the packages, which is how
# apt has always worked and what dnf checks with repo_gpgcheck; the packages
# stay byte-for-byte the release assets.
repo_base='https://packages.harpworks.org'
repo_key() {
  cat <<'KEY'
-----BEGIN PGP PUBLIC KEY BLOCK-----

mDMEaphYuhYJKwYBBAHaRw8BAQdAoaPIHqgnM5jdaH1DCqbHAEa+uiuFD6MXU8Vd
tVq/Oxq0LmNvZGF2b3ggcGFja2FnZSByZXBvc2l0b3J5IDxtaWtlQG1pa2VoYXJw
LmNvbT6IrwQTFgoAVxYhBLJFJ05yjoX6acnX6HAKfqIswmX2BQJqmFi6GxSAAAAA
AAQADm1hbnUyLDIuNSsxLjEyLDAsMwIbAwULCQgHAgIiAgYVCgkICwIEFgIDAQIe
BwIXgAAKCRBwCn6iLMJl9tUTAQCakQBj41z8kFZe2K9b20h81X3q7tftzjeZucKY
TIpqrAD+OG3Gixchbts00EDMKIArGQXj2lM6bvnR4euNTn4vbAQ=
=91iS
-----END PGP PUBLIC KEY BLOCK-----
KEY
}

url="$package_url"

if [ "$os_family" = 'Debian' ]; then
  export DEBIAN_FRONTEND=noninteractive
  if [ -n "$url" ]; then
    case "$url" in
      http*://*)
        # apt cannot install from a URL, so fetch it first.
        tmp="$(mktemp --suffix=.deb)"
        curl -fsSL -o "$tmp" "$url"
        apt-get install -y "$tmp" >&2
        rm -f "$tmp" ;;
      *)
        apt-get install -y "$url" >&2 ;;
    esac
  else
    [ -n "$version" ] || { printf '{"status":"fail","error":"version or package_url required"}\n'; exit 1; }
    install -d -m 0755 /etc/apt/keyrings
    repo_key > /etc/apt/keyrings/harpworks.asc
    printf 'deb [signed-by=/etc/apt/keyrings/harpworks.asc] %s/deb stable main\n' "$repo_base" \
      > /etc/apt/sources.list.d/harpworks.list
    apt-get update -qq >&2
    apt-get install -y "codavox=${version}" >&2
  fi
elif [ "$os_family" = 'RedHat' ]; then
  if [ -n "$url" ]; then
    # yum/dnf install from a URL or a local path directly.
    yum install -y "$url" >&2
  else
    [ -n "$version" ] || { printf '{"status":"fail","error":"version or package_url required"}\n'; exit 1; }
    repo_key > /etc/pki/rpm-gpg/RPM-GPG-KEY-harpworks
    cat > /etc/yum.repos.d/harpworks.repo <<REPO
[harpworks]
name=harpworks - tools for OpenVox
baseurl=${repo_base}/rpm
enabled=1
gpgcheck=0
repo_gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-harpworks
REPO
    yum install -y "codavox-${version}" >&2
  fi
else
  printf '{"status":"fail","error":"unsupported OS family"}\n'
  exit 1
fi

installed="$(codavox version 2>/dev/null || echo unknown)"
printf '{"status":"success","version":"%s"}\n' "$installed"
