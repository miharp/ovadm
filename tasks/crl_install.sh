#!/bin/bash
# Install the CA's CRLs on a host: the copy beside its certificates (hostcrl)
# that the agent checks the server against and, on a compiler, that
# puppetserver checks every client against.
#
# An agent refreshes that file itself once it is a day old
# (crl_refresh_interval), over a connection it verifies with the copy it has.
# This task is for the hosts that cannot wait or cannot fetch: a compiler,
# which goes on serving a revoked host until its copy says otherwise, and any
# host whose copy has run out.
#
# The CRLs are checked before anything is written: each must be signed by a
# certificate in the CA bundle this host already trusts, and none may be
# older than the one the host has. Nothing is restarted: puppetserver reloads
# the file when it changes.
#
# The parameters come as JSON on standard input, not in the environment: the
# CRL of a CA with a few thousand revocations is longer than Linux allows one
# environment variable or one argument (131,072 bytes).
set -euo pipefail

export PATH="/opt/puppetlabs/bin:$PATH"

RUBY='/opt/puppetlabs/puppet/bin/ruby'

if [ ! -x "$RUBY" ]; then
  cat >/dev/null
  printf '{"status":"not_installed","changed":false}\n'
  exit 0
fi

settings=''
if command -v puppet >/dev/null 2>&1; then
  settings=$(puppet config print certname localcacert hostcert hostcrl --section agent 2>/dev/null </dev/null || true)
fi

# Ruby reads its script from the here-document, so the parameters move to
# file descriptor 3 first.
PUPPET_SETTINGS="$settings" "$RUBY" 3<&0 <<'RUBY'
require 'json'
require 'openssl'
require 'socket'
require 'time'

PEM_CERT = /-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----/m
PEM_CRL  = /-----BEGIN X509 CRL-----.+?-----END X509 CRL-----/m

refuse = lambda do |msg|
  puts JSON.generate('changed' => false, '_error' => { 'kind' => 'ovadm/crl-install', 'msg' => "#{msg} Nothing was changed." })
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

crl_number = lambda do |crl|
  extension = crl.extensions.find { |ext| ext.oid == 'crlNumber' }
  extension ? OpenSSL::ASN1.decode(OpenSSL::ASN1.decode(extension.to_der).value.last.value).value.to_i : -1
end
describe = lambda do |crl|
  {
    'issuer'      => name_of.call(crl.issuer),
    'crl_number'  => crl_number.call(crl),
    'revoked'     => crl.revoked.length,
    'next_update' => crl.next_update.utc.iso8601,
    'expired'     => crl.next_update < now,
  }
end

begin
  params = JSON.parse(IO.for_fd(3).read)
rescue JSON::ParserError, SystemCallError => e
  refuse.call("The task's parameters cannot be read (#{e.message}).")
end

begin
  given = params['crl'].to_s.scan(PEM_CRL).map { |pem| OpenSSL::X509::CRL.new(pem) }
rescue OpenSSL::OpenSSLError => e
  refuse.call("The CRLs given cannot be read (#{e.message}).")
end
refuse.call('The CRLs given hold no CRL.') if given.empty?

# A host that trusts no CA has nothing a CRL could be checked against, and
# nothing that reads one.
unless File.file?(localcacert)
  puts JSON.generate('status' => 'not_enrolled', 'certname' => certname, 'changed' => false,
                     'detail' => "#{localcacert} does not exist")
  exit 0
end

begin
  bundle = File.read(localcacert).scan(PEM_CERT).map { |pem| OpenSSL::X509::Certificate.new(pem) }
rescue SystemCallError, OpenSSL::OpenSSLError => e
  refuse.call("#{localcacert} cannot be read (#{e.message}).")
end
refuse.call("#{localcacert} holds no certificate.") if bundle.empty?

given.each do |crl|
  issuer = bundle.find { |cert| cert.subject.cmp(crl.issuer).zero? && crl.verify(cert.public_key) }
  unless issuer
    refuse.call("The CRL of #{name_of.call(crl.issuer)} given is not signed by a certificate in #{localcacert}, the CA this host trusts.")
  end
  if crl.next_update < now
    refuse.call("The CRL of #{name_of.call(crl.issuer)} given ran out on #{crl.next_update.utc.iso8601}. " \
                'The server renews the CRL of its signing CA when it starts; ovadm::extend_ca re-signs the others.')
  end
end

result = { 'certname' => certname, 'path' => hostcrl, 'crls' => given.map { |crl| describe.call(crl) } }

# Whether the host's own certificate is on the CRLs given, which the plan
# says out loud: a revoked compiler is refused by every agent.
if File.file?(hostcert)
  begin
    own = OpenSSL::X509::Certificate.new(File.read(hostcert))
    issued_by = given.find { |crl| crl.issuer.cmp(own.issuer).zero? }
    result['host_cert_revoked'] = !issued_by.nil? && issued_by.revoked.any? { |entry| entry.serial == own.serial }
  rescue SystemCallError, OpenSSL::OpenSSLError
    result['host_cert_revoked'] = nil
  end
else
  result['host_cert_revoked'] = nil
end

# A host without the file checks nothing against a CRL (certificate_revocation
# = false), or will fetch the whole list on its next agent run.
unless File.file?(hostcrl)
  puts JSON.generate(result.merge('status' => 'absent', 'changed' => false, 'previous' => []))
  exit 0
end

begin
  local = File.read(hostcrl).scan(PEM_CRL).map { |pem| OpenSSL::X509::CRL.new(pem) }
rescue SystemCallError, OpenSSL::OpenSSLError => e
  # A file that cannot be parsed protects nobody; the list from the CA does.
  local = []
  result['unreadable'] = e.message
end
result['previous'] = local.map { |crl| describe.call(crl) }

if !local.empty? && local.map(&:to_der).sort == given.map(&:to_der).sort
  puts JSON.generate(result.merge('status' => 'unchanged', 'changed' => false))
  exit 0
end

# Never an older list: a host that has fetched a later CRL than the one in
# hand keeps it.
newer_here = local.any? do |mine|
  theirs = given.find { |crl| crl.issuer.cmp(mine.issuer).zero? }
  theirs && crl_number.call(mine) > crl_number.call(theirs)
end
if newer_here
  puts JSON.generate(result.merge('status' => 'kept_newer', 'changed' => false))
  exit 0
end

# Written beside the old file and renamed over it, keeping owner and mode.
begin
  stat = File.stat(hostcrl)
  staging = "#{hostcrl}.ovadm-new"
  File.open(staging, File::WRONLY | File::CREAT | File::TRUNC, stat.mode & 0o7777) do |file|
    file.write(given.map(&:to_pem).join)
    file.fsync
  end
  File.chown(stat.uid, stat.gid, staging)
  File.chmod(stat.mode & 0o7777, staging)
  File.rename(staging, hostcrl)
rescue SystemCallError => e
  File.unlink(staging) if staging && File.exist?(staging)
  puts JSON.generate(result.merge('changed' => false, '_error' => {
    'kind' => 'ovadm/crl-install',
    'msg'  => "Could not write #{hostcrl} (#{e.message}). Nothing was changed.",
  }))
  exit 1
end

puts JSON.generate(result.merge('status' => 'updated', 'changed' => true))
RUBY
