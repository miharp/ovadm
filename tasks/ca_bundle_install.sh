#!/bin/bash
# Install an extended CA bundle on a host: the copy the agent and the server
# trust (localcacert), the CRLs beside it (hostcrl) and, where OpenVoxDB runs
# on the host, its own copy of the CA, which nothing else refreshes.
#
# An agent whose copy is still valid fetches the new bundle by itself within
# ca_refresh_interval. This task is for the hosts that cannot wait or cannot
# fetch: the CA host and the compilers, which load the bundle when
# puppetserver starts, and any host whose copy has already expired.
#
# The bundle is checked before anything is written: it must hold a valid CA
# certificate whose key signed this host's own certificate. A bundle from a
# different CA is refused, so this cannot be used to change what a host
# trusts, only to refresh it.
set -euo pipefail

export PATH="/opt/puppetlabs/bin:$PATH"

RUBY='/opt/puppetlabs/puppet/bin/ruby'

if [ ! -x "$RUBY" ]; then
  printf '{"status":"not_installed","changed":[]}\n'
  exit 0
fi

settings=''
if command -v puppet >/dev/null 2>&1; then
  settings=$(puppet config print certname localcacert hostcert hostcrl --section agent 2>/dev/null || true)
fi

PUPPET_SETTINGS="$settings" BUNDLE="${PT_bundle}" CRL="${PT_crl:-}" "$RUBY" <<'RUBY'
require 'fileutils'
require 'json'
require 'openssl'
require 'socket'
require 'time'

PEM_CERT = /-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----/m
PEM_CRL  = /-----BEGIN X509 CRL-----.+?-----END X509 CRL-----/m

refuse = lambda do |msg|
  puts JSON.generate('changed' => [], '_error' => { 'kind' => 'ovadm/ca-bundle-install', 'msg' => "#{msg} Nothing was changed." })
  exit 1
end

settings = ENV.fetch('PUPPET_SETTINGS', '').lines.each_with_object({}) do |line, memo|
  key, value = line.split('=', 2)
  memo[key.strip] = value.strip unless value.nil? || value.strip.empty?
end

certname    = settings['certname'] || Socket.gethostname
localcacert = settings['localcacert'] || '/etc/puppetlabs/puppet/ssl/certs/ca.pem'
hostcert    = settings['hostcert'] || "/etc/puppetlabs/puppet/ssl/certs/#{certname}.pem"
hostcrl     = settings['hostcrl'] || '/etc/puppetlabs/puppet/ssl/crl.pem'

now     = Time.now.utc
name_of = ->(name) { name.to_s(OpenSSL::X509::Name::RFC2253) }

begin
  bundle = ENV.fetch('BUNDLE', '').scan(PEM_CERT).map { |pem| OpenSSL::X509::Certificate.new(pem) }
  crls   = ENV.fetch('CRL', '').scan(PEM_CRL).map { |pem| OpenSSL::X509::CRL.new(pem) }
rescue OpenSSL::OpenSSLError => e
  refuse.call("The bundle given cannot be read (#{e.message}).")
end
refuse.call('The bundle given holds no certificate.') if bundle.empty?

bundle.each do |cert|
  subject = name_of.call(cert.subject)
  refuse.call("#{subject} in the bundle given expired on #{cert.not_after.utc.iso8601}.") if cert.not_after < now
  issuer = bundle.find { |candidate| candidate.subject.cmp(cert.issuer).zero? }
  unless issuer && cert.verify(issuer.public_key)
    refuse.call("#{subject} in the bundle given is not signed by a certificate in it.")
  end
end

# A host that never enrolled has nothing that depends on the bundle.
unless File.file?(hostcert)
  puts JSON.generate('status' => 'not_enrolled', 'certname' => certname, 'changed' => [],
                     'detail' => "#{hostcert} does not exist")
  exit 0
end

begin
  own = OpenSSL::X509::Certificate.new(File.read(hostcert))
rescue SystemCallError, OpenSSL::OpenSSLError => e
  refuse.call("#{hostcert} cannot be read (#{e.message}).")
end
# By signature and not by date: an expired host certificate still says which
# CA it belongs to.
signer = bundle.find { |cert| cert.subject.cmp(own.issuer).zero? && own.verify(cert.public_key) }
unless signer
  refuse.call("The bundle given is not the CA that signed #{hostcert} (issued by #{name_of.call(own.issuer)}).")
end

crls.each do |crl|
  issuer = bundle.find { |cert| cert.subject.cmp(crl.issuer).zero? }
  unless issuer && crl.verify(issuer.public_key)
    refuse.call("The CRL of #{name_of.call(crl.issuer)} given is not signed by a certificate in the bundle.")
  end
end

# Written beside the old file and renamed over it, keeping owner and mode.
write = lambda do |path, content|
  stat = File.stat(path) if File.exist?(path)
  staging = "#{path}.ovadm-new"
  File.open(staging, File::WRONLY | File::CREAT | File::TRUNC, stat ? stat.mode & 0o7777 : 0o644) do |file|
    file.write(content)
    file.fsync
  end
  if stat
    File.chown(stat.uid, stat.gid, staging)
    File.chmod(stat.mode & 0o7777, staging)
  end
  File.rename(staging, path)
end

same_certs = lambda do |path|
  File.file?(path) &&
    File.read(path).scan(PEM_CERT).map { |pem| OpenSSL::X509::Certificate.new(pem).to_der }.sort == bundle.map(&:to_der).sort
end

crl_number = lambda do |crl|
  extension = crl.extensions.find { |ext| ext.oid == 'crlNumber' }
  extension ? OpenSSL::ASN1.decode(OpenSSL::ASN1.decode(extension.to_der).value.last.value).value.to_i : -1
end

changed = []
result = { 'certname' => certname }
bundle_pem = bundle.map(&:to_pem).join

begin
  # --- the bundle the agent and the server trust --------------------------
  if same_certs.call(localcacert)
    result['localcacert'] = { 'path' => localcacert, 'action' => 'unchanged' }
  else
    FileUtils.mkdir_p(File.dirname(localcacert))
    write.call(localcacert, bundle_pem)
    changed << localcacert
    result['localcacert'] = { 'path' => localcacert, 'action' => 'updated' }
  end

  # --- the CRLs: only where the host keeps them, and never an older set ----
  if crls.empty?
    result['hostcrl'] = nil
  elsif !File.file?(hostcrl)
    result['hostcrl'] = { 'path' => hostcrl, 'action' => 'absent' }
  else
    local = File.read(hostcrl).scan(PEM_CRL).map { |pem| OpenSSL::X509::CRL.new(pem) }
    newer_here = local.any? do |mine|
      theirs = crls.find { |crl| crl.issuer.cmp(mine.issuer).zero? }
      theirs && crl_number.call(mine) > crl_number.call(theirs)
    end
    if local.map(&:to_der).sort == crls.map(&:to_der).sort
      result['hostcrl'] = { 'path' => hostcrl, 'action' => 'unchanged' }
    elsif newer_here
      result['hostcrl'] = { 'path' => hostcrl, 'action' => 'kept_newer' }
    else
      write.call(hostcrl, crls.map(&:to_pem).join)
      changed << hostcrl
      result['hostcrl'] = { 'path' => hostcrl, 'action' => 'updated' }
    end
  end

  # --- OpenVoxDB's copy ---------------------------------------------------
  jetty_ini = '/etc/puppetlabs/puppetdb/conf.d/jetty.ini'
  pdb_ca = '/etc/puppetlabs/puppetdb/ssl/ca.pem'
  if File.file?(jetty_ini)
    line = File.readlines(jetty_ini).find { |l| l =~ /^\s*ssl-ca-cert\s*=/ }
    pdb_ca = line.split('=', 2)[1].strip if line
  end
  if !File.file?(pdb_ca)
    result['openvoxdb_ca'] = nil
  elsif File.identical?(pdb_ca, localcacert)
    # OpenVoxDB reads the host's own bundle: the same path, or a link to it.
    # There is no second file to write, but OpenVoxDB loaded the old one and
    # needs its restart as much as it would for a copy.
    result['openvoxdb_ca'] = { 'path' => pdb_ca, 'action' => result['localcacert']['action'], 'shared_with' => localcacert }
  elsif same_certs.call(pdb_ca)
    result['openvoxdb_ca'] = { 'path' => pdb_ca, 'action' => 'unchanged' }
  else
    write.call(pdb_ca, bundle_pem)
    changed << pdb_ca
    result['openvoxdb_ca'] = { 'path' => pdb_ca, 'action' => 'updated' }
  end
rescue SystemCallError, OpenSSL::OpenSSLError => e
  puts JSON.generate(result.merge('changed' => changed, '_error' => {
    'kind' => 'ovadm/ca-bundle-install',
    'msg'  => "Could not install the bundle (#{e.message}). Changed before that: #{changed.empty? ? 'nothing' : changed.join(', ')}.",
  }))
  exit 1
end

earliest = bundle.min_by(&:not_after)
puts JSON.generate(result.merge(
  'status'    => changed.empty? ? 'unchanged' : 'installed',
  'changed'   => changed,
  'not_after' => earliest.not_after.utc.iso8601,
  'host_cert' => {
    'path'      => hostcert,
    'not_after' => own.not_after.utc.iso8601,
    'days_left' => ((own.not_after - now) / 86_400).floor,
    'expired'   => own.not_after < now,
  }
))
RUBY
