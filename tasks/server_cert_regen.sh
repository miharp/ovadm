#!/bin/bash
# Replace the CA host's own certificate with a new one from its own CA: the
# documented procedure for a server certificate that has expired. On a CA
# that puppetserver generated for itself (a single self-signed certificate),
# the server's certificate was signed in the same second as the CA with the
# same lifetime, so the two expire together and extending the CA alone does
# not bring the server back.
#
# The old certificate, its keys and the CA's signed copy are kept in a
# directory beside ssldir, then removed, and `puppetserver ca generate
# --ca-client` issues the replacement offline with the subject alternative
# names of the old certificate, which the command does not carry over by
# itself. If that fails, the old files are put back.
#
# Only for the CA host. A compiler's certificate comes from another host's
# CA and is replaced the way an agent's is.
set -euo pipefail

export PATH="/opt/puppetlabs/bin:$PATH"

RUBY='/opt/puppetlabs/puppet/bin/ruby'

force="${PT_force:-false}"

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' '
}

fail() {
  printf '{"_error":{"kind":"ovadm/server-cert-regen","msg":"%s"}}\n' "$(json_escape "$1")"
  exit 1
}

command -v puppetserver >/dev/null 2>&1 || fail 'puppetserver is not installed on this host.'
[ -x "$RUBY" ] || fail "${RUBY} is missing."

setting() {
  puppet config print "$1" --section server 2>/dev/null || true
}
certname=$(setting certname)
cadir=$(setting cadir)
ssldir=$(setting ssldir)
hostcert=$(setting hostcert)
hostprivkey=$(setting hostprivkey)
hostpubkey=$(setting hostpubkey)
[ -n "$certname" ] && [ -n "$ssldir" ] && [ -n "$hostcert" ] || fail 'Could not read the certname and ssldir settings.'
cadir=${cadir:-/etc/puppetlabs/puppetserver/ca}
signed="${cadir}/signed/${certname}.pem"

[ -f "${cadir}/ca_crt.pem" ] || fail "${cadir}/ca_crt.pem does not exist: this host is not the CA. A compiler's certificate is replaced the way an agent's is."
[ -f "$hostcert" ] || fail "${hostcert} does not exist: there is no certificate to replace."

if [ "$force" != true ] && command -v systemctl >/dev/null 2>&1 \
  && systemctl is-active --quiet puppetserver 2>/dev/null; then
  fail 'puppetserver is running. Stop it first (ovadm::extend_ca does), or pass force=true.'
fi

# What the old certificate says, read before it is moved away: its expiry,
# its alternative names in the form `puppetserver ca generate` takes, and the
# extensions it carries, to compare with the new one.
describe() {
  CERT="$1" "$RUBY" <<'RUBY'
require 'openssl'
require 'time'
cert = OpenSSL::X509::Certificate.new(File.read(ENV['CERT']))
san = cert.extensions.find { |ext| ext.oid == 'subjectAltName' }
names = san ? san.value.split(/,\s*/) : []
kept = names.map { |name| name.sub(/\AIP Address:/, 'IP:') }.select { |name| name =~ /\A(DNS|IP):/ }.uniq
puts cert.not_after.utc.iso8601
puts kept.join(',')
puts (names.length - names.select { |name| name =~ /\A(DNS|IP Address):/ }.length).to_s
puts cert.extensions.map(&:oid).sort.join(',')
RUBY
}
old=$(describe "$hostcert") || fail "${hostcert} cannot be read."
old_not_after=$(sed -n 1p <<<"$old")
alt_names=$(sed -n 2p <<<"$old")
alt_names_dropped=$(sed -n 3p <<<"$old")
old_extensions=$(sed -n 4p <<<"$old")

stamp=$(date -u +%Y%m%dT%H%M%SZ)
backup="${ssldir%/}.server-cert.${stamp}.bak"
install -d -m 0700 "$backup"
kept_files=()
for f in "$hostcert" "$hostprivkey" "$hostpubkey" "$signed"; do
  [ -f "$f" ] || continue
  install -d -m 0700 "${backup}$(dirname "$f")"
  cp -p "$f" "${backup}${f}"
  kept_files+=("$f")
done

put_back() {
  for f in "${kept_files[@]}"; do
    cp -p "${backup}${f}" "$f"
  done
}

rm -f "$hostcert" "$hostprivkey" "$hostpubkey" "$signed" "${cadir}/requests/${certname}.pem"

args=(ca generate --certname "$certname" --ca-client)
if [ -n "$alt_names" ]; then
  args+=(--subject-alt-names "$alt_names")
fi

# The command checks over the network that no server is running and stops
# when it cannot tell, for instance when the server's name does not resolve
# from the server itself. The service was checked above, so it is told to go
# on.
if ! output=$(puppetserver "${args[@]}" 2>&1); then
  if ! grep -q -- '--force' <<<"$output" || ! output=$(puppetserver "${args[@]}" --force 2>&1); then
    put_back
    fail "puppetserver ${args[*]} failed, and the old certificate and keys were put back: ${output}"
  fi
fi
if [ ! -f "$hostcert" ]; then
  put_back
  fail "puppetserver ${args[*]} did not write ${hostcert}, and the old certificate and keys were put back: ${output}"
fi

new=$(describe "$hostcert") || fail "The new ${hostcert} cannot be read. The old files are in ${backup}."

# `ca generate --ca-client` signs offline and does not add the certificate to
# the CA's inventory, which the server reads to find a certname's serial and
# to drop expired entries from the CRL. Add the line the server would have
# written, unless a later release has started writing it.
inventory="${cadir}/inventory.txt"
if [ -f "$inventory" ]; then
  line=$(CERT="$hostcert" "$RUBY" -ropenssl -e '
    cert = OpenSSL::X509::Certificate.new(File.read(ENV["CERT"]))
    stamp = "%Y-%m-%dT%H:%M:%SUTC"
    subject = cert.subject.to_a.map { |part| "#{part[0]}=#{part[1]}" }.join("/")
    puts format("0x%04x %s %s /%s", cert.serial.to_i, cert.not_before.utc.strftime(stamp),
                cert.not_after.utc.strftime(stamp), subject)
  ' 2>/dev/null || true)
  if [ -n "$line" ] && ! grep -q "^${line%% *} " "$inventory"; then
    printf '%s\n' "$line" >> "$inventory"
  fi
fi
new_not_after=$(sed -n 1p <<<"$new")
new_extensions=$(sed -n 4p <<<"$new")
lost=$(LC_ALL=C comm -23 <(tr ',' '\n' <<<"$old_extensions" | LC_ALL=C sort) <(tr ',' '\n' <<<"$new_extensions" | LC_ALL=C sort) | paste -sd, -)

# OpenVoxDB keeps copies of the server's certificate and key when it runs on
# the same host. They are replaced only when the copy is the certificate just
# retired; a certificate OpenVoxDB was given separately is left alone.
openvoxdb='null'
jetty_ini='/etc/puppetlabs/puppetdb/conf.d/jetty.ini'
pdb_cert='/etc/puppetlabs/puppetdb/ssl/public.pem'
pdb_key='/etc/puppetlabs/puppetdb/ssl/private.pem'
if [ -f "$jetty_ini" ]; then
  v=$(sed -n 's/^[[:space:]]*ssl-cert[[:space:]]*=[[:space:]]*//p' "$jetty_ini" | head -1 | tr -d '[:space:]')
  [ -n "$v" ] && pdb_cert="$v"
  v=$(sed -n 's/^[[:space:]]*ssl-key[[:space:]]*=[[:space:]]*//p' "$jetty_ini" | head -1 | tr -d '[:space:]')
  [ -n "$v" ] && pdb_key="$v"
fi
if [ -f "$pdb_cert" ] && [ -f "$pdb_key" ] && [ -f "${backup}${hostcert}" ]; then
  if [ "$(sha256sum < "$pdb_cert")" = "$(sha256sum < "${backup}${hostcert}")" ]; then
    install -d -m 0700 "${backup}$(dirname "$pdb_cert")"
    cp -p "$pdb_cert" "${backup}${pdb_cert}"
    cp -p "$pdb_key" "${backup}${pdb_key}"
    # Written into the existing files, so they keep their owner and mode.
    cat "$hostcert" > "$pdb_cert"
    cat "$hostprivkey" > "$pdb_key"
    openvoxdb='"updated"'
  else
    openvoxdb='"left"'
  fi
fi

printf '{"status":"regenerated","certname":"%s","hostcert":"%s","old_not_after":"%s","new_not_after":"%s","subject_alt_names":"%s","alt_names_dropped":%s,"extensions_lost":"%s","backup":"%s","openvoxdb":%s}\n' \
  "$(json_escape "$certname")" "$(json_escape "$hostcert")" "$old_not_after" "$new_not_after" \
  "$(json_escape "$alt_names")" "${alt_names_dropped:-0}" "$(json_escape "$lost")" "$(json_escape "$backup")" "$openvoxdb"
