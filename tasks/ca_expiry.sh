#!/bin/bash
# Report when the certificates this host depends on expire. On the CA: every
# certificate in the CA directory's bundle, whether its private key is on
# disk (so whether ovadm::ca_extend can re-sign it) and every CRL the CA
# keeps. On any host: its copy of the CA bundle and of the CRLs, its own
# certificate, and OpenVoxDB's copy of the CA where there is one. Read-only,
# and works with the services stopped: everything comes from files.
set -euo pipefail

export PATH="/opt/puppetlabs/bin:$PATH"

RUBY='/opt/puppetlabs/puppet/bin/ruby'

# The certificates are read with the agent's Ruby. A host without it has no
# OpenVox on it, and so nothing to report.
if [ ! -x "$RUBY" ]; then
  printf '{"status":"not_installed","certname":null,"ca":null,"local_ca":null,"host_cert":null,"host_crl":null,"openvoxdb_ca":null}\n'
  exit 0
fi

settings=''
if command -v puppet >/dev/null 2>&1; then
  settings=$(puppet config print certname cadir cacert cakey cacrl localcacert hostcert hostcrl --section server 2>/dev/null || true)
fi

PUPPET_SETTINGS="$settings" INCLUDE_BUNDLE="${PT_include_bundle:-false}" "$RUBY" <<'RUBY'
require 'json'
require 'openssl'
require 'socket'
require 'time'

PEM_CERT = /-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----/m
PEM_CRL  = /-----BEGIN X509 CRL-----.+?-----END X509 CRL-----/m

settings = ENV.fetch('PUPPET_SETTINGS', '').lines.each_with_object({}) do |line, memo|
  key, value = line.split('=', 2)
  memo[key.strip] = value.strip unless value.nil? || value.strip.empty?
end

certname    = settings['certname'] || Socket.gethostname
cadir       = settings['cadir'] || '/etc/puppetlabs/puppetserver/ca'
cacert      = settings['cacert'] || File.join(cadir, 'ca_crt.pem')
cakey       = settings['cakey'] || File.join(cadir, 'ca_key.pem')
cacrl       = settings['cacrl'] || File.join(cadir, 'ca_crl.pem')
rootkey     = File.join(cadir, 'root_key.pem')
infra_crl   = File.join(cadir, 'infra_crl.pem')
localcacert = settings['localcacert'] || '/etc/puppetlabs/puppet/ssl/certs/ca.pem'
hostcert    = settings['hostcert'] || "/etc/puppetlabs/puppet/ssl/certs/#{certname}.pem"
hostcrl     = settings['hostcrl'] || '/etc/puppetlabs/puppet/ssl/crl.pem'

now = Time.now.utc

name_of   = ->(name) { name.to_s(OpenSSL::X509::Name::RFC2253) }
days_left = ->(time) { ((time - now) / 86_400).floor }
read_certs = lambda do |path|
  File.read(path).scan(PEM_CERT).map { |pem| OpenSSL::X509::Certificate.new(pem) }
end
read_crls = lambda do |path|
  File.read(path).scan(PEM_CRL).map { |pem| OpenSSL::X509::CRL.new(pem) }
end
fingerprint = ->(cert) { OpenSSL::Digest.new('SHA256').hexdigest(cert.to_der).upcase }

describe_cert = lambda do |cert|
  {
    'subject'     => name_of.call(cert.subject),
    'issuer'      => name_of.call(cert.issuer),
    'serial'      => cert.serial.to_s(16).upcase,
    'not_before'  => cert.not_before.utc.iso8601,
    'not_after'   => cert.not_after.utc.iso8601,
    'days_left'   => days_left.call(cert.not_after),
    'expired'     => cert.not_after < now,
    'fingerprint' => fingerprint.call(cert),
  }
end

describe_crl = lambda do |crl|
  number = crl.extensions.find { |ext| ext.oid == 'crlNumber' }
  {
    'issuer'      => name_of.call(crl.issuer),
    'last_update' => crl.last_update.utc.iso8601,
    'next_update' => crl.next_update.utc.iso8601,
    'days_left'   => days_left.call(crl.next_update),
    'expired'     => crl.next_update < now,
    'crl_number'  => number && number.value.to_i,
    'revoked'     => crl.revoked.length,
  }
end

# The earliest expiry among a set of described certificates or CRLs.
soonest = lambda do |described, field|
  first = described.min_by { |d| d[field] }
  first ? { field => first[field], 'days_left' => first['days_left'], 'expired' => first['expired'] } : {}
end

# --- the CA directory ----------------------------------------------------
ca = nil
ca_certs = []
if File.file?(cacert)
  problems = []
  begin
    ca_certs = read_certs.call(cacert)
  rescue SystemCallError, OpenSSL::OpenSSLError => e
    problems << "#{cacert} cannot be read (#{e.message})"
  end
  problems << "#{cacert} holds no certificate" if ca_certs.empty? && problems.empty?

  keys = {}
  [cakey, rootkey].each do |path|
    next unless File.file?(path)

    begin
      keys[path] = OpenSSL::PKey.read(File.read(path))
    rescue SystemCallError, OpenSSL::OpenSSLError => e
      problems << "#{path} cannot be read (#{e.message})"
    end
  end

  subjects = ca_certs.map { |cert| name_of.call(cert.subject) }
  used_keys = []
  certificates = ca_certs.map do |cert|
    subject = name_of.call(cert.subject)
    issuer  = name_of.call(cert.issuer)
    key_path, = keys.find { |_, key| cert.check_private_key(key) }
    used_keys << key_path if key_path
    role = if subject == issuer
             'root'
           elsif subjects.include?(issuer)
             'intermediate'
           else
             'external'
           end
    if role == 'external'
      problems << "#{subject} was issued by #{issuer}, which is not in the bundle: an externally issued CA is extended by its owner"
    elsif key_path.nil?
      problems << "the private key of #{subject} is not on this host: an externally issued CA is extended by its owner"
    end
    describe_cert.call(cert).merge('role' => role, 'key' => key_path)
  end
  if keys.key?(cakey) && !used_keys.include?(cakey) && !ca_certs.empty?
    problems << "#{cakey} matches no certificate in #{cacert}"
  end
  problems << "#{cakey} is missing" unless File.file?(cakey)

  layout = if certificates.length == 1 && certificates[0]['role'] == 'root'
             'single'
           elsif certificates.length == 2 && certificates.map { |c| c['role'] }.sort == %w[intermediate root]
             'intermediate'
           else
             'other'
           end

  crls = []
  [cacrl, infra_crl].uniq.each do |path|
    next unless File.file?(path)

    begin
      read_crls.call(path).each { |crl| crls << describe_crl.call(crl).merge('path' => path) }
    rescue SystemCallError, OpenSSL::OpenSSLError => e
      problems << "#{path} cannot be read (#{e.message})"
    end
  end

  ca = {
    'path'         => cacert,
    'layout'       => layout,
    'extendable'   => problems.empty?,
    'problems'     => problems.uniq,
    'certificates' => certificates,
    'crls'         => crls,
  }.merge(soonest.call(certificates, 'not_after'))
  # The bundle itself, for ovadm::ca_bundle_install on other hosts.
  if ENV['INCLUDE_BUNDLE'] == 'true' && !ca_certs.empty?
    ca['bundle'] = ca_certs.map(&:to_pem).join
    ca['crl'] = File.file?(cacrl) ? File.read(cacrl) : nil
  end
end

# --- this host's copy of the CA, its CRLs and its own certificate ----------
local_ca = nil
local_certs = []
if File.file?(localcacert)
  begin
    local_certs = read_certs.call(localcacert)
    described = local_certs.map { |cert| describe_cert.call(cert) }
    local_ca = {
      'path'         => localcacert,
      'certificates' => described,
      'matches_ca'   => ca.nil? ? nil : local_certs.map(&:to_der).sort == ca_certs.map(&:to_der).sort,
    }.merge(soonest.call(described, 'not_after'))
  rescue SystemCallError, OpenSSL::OpenSSLError => e
    local_ca = { 'path' => localcacert, 'error' => e.message, 'certificates' => [], 'matches_ca' => nil }
  end
end

host_crl = nil
if File.file?(hostcrl)
  begin
    described = read_crls.call(hostcrl).map { |crl| describe_crl.call(crl) }
    host_crl = { 'path' => hostcrl, 'crls' => described }.merge(soonest.call(described, 'next_update'))
  rescue SystemCallError, OpenSSL::OpenSSLError => e
    host_crl = { 'path' => hostcrl, 'error' => e.message, 'crls' => [] }
  end
end

host_cert = nil
if File.file?(hostcert)
  begin
    cert = OpenSSL::X509::Certificate.new(File.read(hostcert))
    # Signed by a key in the local bundle, whatever the dates say.
    signer = local_certs.find { |c| c.subject.cmp(cert.issuer).zero? && cert.verify(c.public_key) }
    host_cert = describe_cert.call(cert).merge('path' => hostcert, 'signed_by_local_ca' => !signer.nil?)
  rescue SystemCallError, OpenSSL::OpenSSLError => e
    host_cert = { 'path' => hostcert, 'error' => e.message }
  end
end

# --- OpenVoxDB's own copy of the CA, which nothing refreshes ---------------
openvoxdb_ca = nil
jetty_ini = '/etc/puppetlabs/puppetdb/conf.d/jetty.ini'
pdb_ca = '/etc/puppetlabs/puppetdb/ssl/ca.pem'
if File.file?(jetty_ini)
  line = File.readlines(jetty_ini).find { |l| l =~ /^\s*ssl-ca-cert\s*=/ }
  pdb_ca = line.split('=', 2)[1].strip if line
end
if File.file?(pdb_ca)
  begin
    pdb_certs = read_certs.call(pdb_ca)
    described = pdb_certs.map { |c| describe_cert.call(c) }
    openvoxdb_ca = {
      'path'          => pdb_ca,
      'certificates'  => described,
      'matches_local' => pdb_certs.map(&:to_der).sort == local_certs.map(&:to_der).sort,
    }.merge(soonest.call(described, 'not_after'))
  rescue SystemCallError, OpenSSL::OpenSSLError => e
    openvoxdb_ca = { 'path' => pdb_ca, 'error' => e.message, 'certificates' => [], 'matches_local' => nil }
  end
end

puts JSON.generate(
  'status'       => 'ok',
  'certname'     => certname,
  'checked'      => now.iso8601,
  'ca'           => ca,
  'local_ca'     => local_ca,
  'host_cert'    => host_cert,
  'host_crl'     => host_crl,
  'openvoxdb_ca' => openvoxdb_ca
)
RUBY
