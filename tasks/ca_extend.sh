#!/bin/bash
# Extend the CA: re-sign every certificate in the CA directory's bundle with
# a later expiry and nothing else changed. Subject, issuer, serial, public
# key and extensions stay as they are and the same keys sign, so every
# certificate the CA ever issued remains valid; only the CA certificate file
# is different afterwards. The CRLs the CA keeps are re-signed to run as long
# as the certificate that issued them, since a root's CRL is written once at
# setup and expires with the root.
#
# Works on a single self-signed CA certificate and on a root plus
# intermediate, before or after they have expired. Refuses a bundle with a
# certificate whose private key is not on this host: an externally issued CA
# is extended by whoever holds its key.
#
# Writes only to the CA directory. The host's own copy of the bundle
# (localcacert), like every other host's, is ovadm::ca_bundle_install's.
set -euo pipefail

export PATH="/opt/puppetlabs/bin:$PATH"

RUBY='/opt/puppetlabs/puppet/bin/ruby'

ttl="${PT_ttl:-15y}"
force="${PT_force:-false}"
noop="${PT__noop:-false}"

fail() {
  printf '{"_error":{"kind":"ovadm/ca-extend","msg":"%s"}}\n' "$1"
  exit 1
}

[ -x "$RUBY" ] || fail "${RUBY} is missing: this host has no OpenVox agent, so it is not the CA"

# A running server holds the CA in memory and rewrites the CRL when a
# certificate is revoked. A dry run changes nothing, so it may look.
if [ "$noop" != true ] && [ "$force" != true ] && command -v systemctl >/dev/null 2>&1 \
  && systemctl is-active --quiet puppetserver 2>/dev/null; then
  fail 'puppetserver is running. Stop it first (ovadm::extend_ca does), or pass force=true.'
fi

settings=''
if command -v puppet >/dev/null 2>&1; then
  settings=$(puppet config print cadir cacert cakey cacrl --section server 2>/dev/null || true)
fi

PUPPET_SETTINGS="$settings" TTL="$ttl" NOOP="$noop" "$RUBY" <<'RUBY'
require 'fileutils'
require 'json'
require 'openssl'
require 'time'

PEM_CERT = /-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----/m
PEM_CRL  = /-----BEGIN X509 CRL-----.+?-----END X509 CRL-----/m
UNITS    = { 's' => 1, 'm' => 60, 'h' => 3600, 'd' => 86_400, 'y' => 31_536_000 }.freeze

refuse = lambda do |msg|
  puts JSON.generate('_error' => { 'kind' => 'ovadm/ca-extend', 'msg' => "#{msg} Nothing was changed." })
  exit 1
end

settings = ENV.fetch('PUPPET_SETTINGS', '').lines.each_with_object({}) do |line, memo|
  key, value = line.split('=', 2)
  memo[key.strip] = value.strip unless value.nil? || value.strip.empty?
end

cadir     = settings['cadir'] || '/etc/puppetlabs/puppetserver/ca'
cacert    = settings['cacert'] || File.join(cadir, 'ca_crt.pem')
cakey     = settings['cakey'] || File.join(cadir, 'ca_key.pem')
cacrl     = settings['cacrl'] || File.join(cadir, 'ca_crl.pem')
rootkey   = File.join(cadir, 'root_key.pem')
infra_crl = File.join(cadir, 'infra_crl.pem')
noop      = ENV['NOOP'] == 'true'

ttl = ENV.fetch('TTL', '15y')
match = ttl.match(/\A(\d+)([smhdy])\z/)
refuse.call("ttl '#{ttl}' is not a duration such as 15y or 5475d.") unless match
seconds = match[1].to_i * UNITS[match[2]]
# The server's own ceiling for a CA lifetime (max-ca-ttl): 50 years.
refuse.call("ttl '#{ttl}' is longer than 50 years.") if seconds > 50 * UNITS['y']

now       = Time.now.utc
not_after = Time.at(now.to_i + seconds).utc
stamp     = now.strftime('%Y%m%dT%H%M%SZ')

name_of = ->(name) { name.to_s(OpenSSL::X509::Name::RFC2253) }
# The digest the certificate or CRL was signed with, and SHA-256 in place of
# anything weaker (a CA from the Puppet 3 days may still carry SHA-1).
digest_for = lambda do |algorithm|
  found = algorithm.to_s.match(/sha(\d{3})/i)
  OpenSSL::Digest.new(found ? "SHA#{found[1]}" : 'SHA256')
end

refuse.call("#{cacert} does not exist: this host is not the CA.") unless File.file?(cacert)

begin
  certs = File.read(cacert).scan(PEM_CERT).map { |pem| OpenSSL::X509::Certificate.new(pem) }
  keys = [cakey, rootkey].select { |path| File.file?(path) }.to_h do |path|
    [path, OpenSSL::PKey.read(File.read(path))]
  end
rescue SystemCallError, OpenSSL::OpenSSLError => e
  refuse.call("The CA's files cannot be read (#{e.message}).")
end
refuse.call("#{cacert} holds no certificate.") if certs.empty?
refuse.call("#{cakey} is missing.") unless keys.key?(cakey)

# Each certificate with the key it belongs to, found by the key itself and
# not by position in the file.
entries = certs.map do |cert|
  key_path, key = keys.find { |_, candidate| cert.check_private_key(candidate) }
  { cert: cert, subject: name_of.call(cert.subject), issuer: name_of.call(cert.issuer), key_path: key_path, key: key }
end
by_subject = entries.to_h { |entry| [entry[:subject], entry] }

external = 'An externally issued CA is extended by whoever holds its key, and brought in with puppetserver ca import.'
entries.each do |entry|
  unless by_subject.key?(entry[:issuer])
    refuse.call("#{entry[:subject]} was issued by #{entry[:issuer]}, which is not in #{cacert}. #{external}")
  end
  refuse.call("The private key of #{entry[:subject]} is not on this host. #{external}") unless entry[:key]
end
unless entries.any? { |entry| entry[:key_path] == cakey }
  refuse.call("#{cakey} matches no certificate in #{cacert}.")
end
if by_subject.length != entries.length
  refuse.call("#{cacert} holds two certificates with the same subject.")
end

entries.each do |entry|
  next if entry[:cert].not_after < not_after

  refuse.call("#{entry[:subject]} already runs until #{entry[:cert].not_after.utc.iso8601}, " \
              "which a ttl of #{ttl} from now (#{not_after.iso8601}) would not extend.")
end

# Issuers before the certificates they sign: a root signs itself, and an
# intermediate is signed by the root's key.
pending = entries.dup
ordered = []
until pending.empty?
  ready = pending.select do |entry|
    entry[:subject] == entry[:issuer] || ordered.any? { |done| done[:subject] == entry[:issuer] }
  end
  refuse.call("The certificates in #{cacert} do not form a chain.") if ready.empty?
  ordered.concat(ready)
  pending -= ready
end

ordered.each do |entry|
  issuer = by_subject[entry[:issuer]]
  renewed = OpenSSL::X509::Certificate.new(entry[:cert].to_der)
  renewed.not_after = not_after
  renewed.sign(issuer[:key], digest_for.call(entry[:cert].signature_algorithm))
  unless renewed.verify(issuer[:key]) && renewed.check_private_key(entry[:key])
    refuse.call("The re-signed #{entry[:subject]} does not verify.")
  end
  entry[:renewed] = renewed
end

# The CRLs. Each one a key here issued gets the expiry of its issuer and the
# next CRL number; the revoked entries are carried over untouched. A CRL from
# anywhere else is left as it is.
warnings = []
crl_number = lambda do |extension|
  OpenSSL::ASN1.decode(OpenSSL::ASN1.decode(extension.to_der).value.last.value).value.to_i
end
crl_files = [cacrl, infra_crl].uniq.select { |path| File.file?(path) }.to_h do |path|
  begin
    crls = File.read(path).scan(PEM_CRL).map { |pem| OpenSSL::X509::CRL.new(pem) }
  rescue SystemCallError, OpenSSL::OpenSSLError => e
    refuse.call("#{path} cannot be read (#{e.message}).")
  end
  described = []
  renewed = crls.map do |crl|
    issuer = by_subject[name_of.call(crl.issuer)]
    unless issuer && crl.verify(issuer[:key])
      warnings << "#{path}: the CRL of #{name_of.call(crl.issuer)} was not issued by a key on this host and was left as it is"
      next crl
    end
    fresh = OpenSSL::X509::CRL.new(crl.to_der)
    fresh.next_update = [crl.next_update, issuer[:renewed].not_after].max
    number = nil
    fresh.extensions = crl.extensions.map do |extension|
      next extension unless extension.oid == 'crlNumber'

      number = crl_number.call(extension) + 1
      OpenSSL::X509::Extension.new('crlNumber', OpenSSL::ASN1::Integer(number))
    end
    fresh.sign(issuer[:key], digest_for.call(crl.signature_algorithm))
    refuse.call("The re-signed CRL of #{issuer[:subject]} does not verify.") unless fresh.verify(issuer[:key])
    described << {
      'path'            => path,
      'issuer'          => issuer[:subject],
      'old_next_update' => crl.next_update.utc.iso8601,
      'new_next_update' => fresh.next_update.utc.iso8601,
      'crl_number'      => number,
      'revoked'         => fresh.revoked.length,
    }
    fresh
  end
  [path, { crls: renewed, described: described }]
end

certificates = entries.map do |entry|
  {
    'subject'       => entry[:subject],
    'role'          => entry[:subject] == entry[:issuer] ? 'root' : 'intermediate',
    'serial'        => entry[:cert].serial.to_s(16).upcase,
    'key'           => entry[:key_path],
    'signed_by'     => by_subject[entry[:issuer]][:key_path],
    'old_not_after' => entry[:cert].not_after.utc.iso8601,
    'new_not_after' => entry[:renewed].not_after.utc.iso8601,
    'was_expired'   => entry[:cert].not_after < now,
  }
end
result = {
  'status'       => noop ? 'noop' : 'extended',
  'path'         => cacert,
  'ttl'          => ttl,
  'certificates' => certificates,
  'crls'         => crl_files.values.flat_map { |file| file[:described] },
  'warnings'     => warnings,
}

if noop
  puts JSON.generate(result.merge('backups' => []))
  exit 0
end

# Same order as the file had, so nothing that reads it by position changes.
contents = { cacert => entries.map { |entry| entry[:renewed].to_pem }.join }
crl_files.each do |path, file|
  contents[path] = file[:crls].map(&:to_pem).join unless file[:described].empty?
end

# A copy of every file first, then every new file written beside the old
# one, then the renames, so a failure leaves either the old set or the new.
backups = []
staged = []
begin
  contents.each_key do |path|
    backup = "#{path}.#{stamp}.bak"
    FileUtils.cp(path, backup, preserve: true)
    backups << backup
  end
  contents.each do |path, content|
    stat = File.stat(path)
    staging = "#{path}.ovadm-new"
    File.open(staging, File::WRONLY | File::CREAT | File::TRUNC, stat.mode & 0o7777) do |file|
      file.write(content)
      file.fsync
    end
    File.chown(stat.uid, stat.gid, staging)
    File.chmod(stat.mode & 0o7777, staging)
    staged << [staging, path]
  end
  staged.each { |staging, path| File.rename(staging, path) }
rescue SystemCallError => e
  staged.each { |staging, _| FileUtils.rm_f(staging) }
  puts JSON.generate('backups' => backups, '_error' => {
    'kind' => 'ovadm/ca-extend',
    'msg'  => "Could not write the CA's files (#{e.message}). Compare them with the copies ending in .#{stamp}.bak.",
  })
  exit 1
end

puts JSON.generate(result.merge(
  'backups' => backups,
  'bundle'  => contents[cacert],
  'crl'     => File.file?(cacrl) ? File.read(cacrl) : nil
))
RUBY
