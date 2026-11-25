#!/bin/bash
# Revoke certificates on the CA with `puppetserver ca revoke`, or with
# clean=true revoke them and delete them from the CA with `puppetserver ca
# clean`. One certname at a time, so each gets its own answer.
#
# The server writes the revocation to its CRL and reloads it within a second. A
# compiler goes on serving the host until its own copy of the CRL is
# replaced: that is ovadm::crl_install, which ovadm::revoke runs next.
#
# Refuses the certname of the host it runs on. That is the CA server, and
# revoking its certificate takes the deployment down.
set -euo pipefail

export PATH="/opt/puppetlabs/bin:$PATH"

RUBY='/opt/puppetlabs/puppet/bin/ruby'

fail() {
  printf '{"results":{},"changed":false,"_error":{"kind":"ovadm/cert-revoke","msg":"%s"}}\n' "$1"
  exit 1
}

command -v puppetserver >/dev/null 2>&1 || fail 'puppetserver is not installed on this host, so it is not the CA. Nothing was changed.'
[ -x "$RUBY" ] || fail "${RUBY} is missing. Nothing was changed."

settings=$(puppet config print certname cadir cacert cacrl --section server 2>/dev/null || true)

PUPPET_SETTINGS="$settings" CERTNAMES="${PT_certnames}" CLEAN="${PT_clean:-false}" "$RUBY" <<'RUBY'
require 'json'
require 'open3'
require 'openssl'
require 'socket'

PEM_CRL = /-----BEGIN X509 CRL-----.+?-----END X509 CRL-----/m

refuse = lambda do |msg|
  puts JSON.generate('results' => {}, 'changed' => false,
                     '_error' => { 'kind' => 'ovadm/cert-revoke', 'msg' => "#{msg} Nothing was changed." })
  exit 1
end

settings = ENV.fetch('PUPPET_SETTINGS', '').lines.each_with_object({}) do |line, memo|
  key, value = line.split('=', 2)
  memo[key.strip] = value.strip unless value.nil? || value.strip.empty?
end

certname = settings['certname'] || Socket.gethostname
cadir    = settings['cadir'] || '/etc/puppetlabs/puppetserver/ca'
cacert   = settings['cacert'] || File.join(cadir, 'ca_crt.pem')
cacrl    = settings['cacrl'] || File.join(cadir, 'ca_crl.pem')
clean    = ENV['CLEAN'] == 'true'

begin
  names = JSON.parse(ENV.fetch('CERTNAMES', '[]'))
rescue JSON::ParserError
  # A single name given as a plain string.
  names = [ENV['CERTNAMES']]
end
names = Array(names).map(&:to_s).uniq
refuse.call('No certname was given.') if names.empty?
names.each do |name|
  # As the CA CLI takes them: no option, no list, no path.
  unless name.match?(/\A[A-Za-z0-9_][A-Za-z0-9._-]*\z/)
    refuse.call("'#{name}' is not a certname.")
  end
  if name == certname
    refuse.call("#{name} is this server's own certificate. Revoking it takes the deployment down.")
  end
end
refuse.call("#{cacert} does not exist: this host is not the CA.") unless File.file?(cacert)

# What the CRLs hold, to tell a revocation that changed something from one
# the CA already had: the CLI answers both the same way.
crl_state = lambda do
  File.read(cacrl).scan(PEM_CRL).map do |pem|
    crl = OpenSSL::X509::CRL.new(pem)
    number = crl.extensions.find { |ext| ext.oid == 'crlNumber' }
    [crl.issuer.to_s, number && number.value, crl.revoked.length]
  end
rescue SystemCallError, OpenSSL::OpenSSLError
  nil
end

action = clean ? 'clean' : 'revoke'
before_all = crl_state.call
results = {}
names.each do |name|
  before = crl_state.call
  output, status = Open3.capture2e('puppetserver', 'ca', action, '--certname', name)
  after = crl_state.call
  newly = !before.nil? && before != after
  detail = output.lines.map(&:strip).reject { |line| line.empty? || line == 'Error:' }.join(' ')

  results[name] =
    case status.exitstatus
    when 0
      { 'status' => newly ? 'revoked' : 'already_revoked', 'cleaned' => clean }
    when 24
      # A request that was never signed: nothing to revoke. clean deletes it.
      { 'status' => 'not_signed', 'cleaned' => clean }
    else
      if detail =~ /Could not find/i
        { 'status' => 'not_found', 'cleaned' => false }
      else
        { 'status' => 'error', 'cleaned' => false, 'detail' => detail }
      end
    end
end

changed = !before_all.nil? && before_all != crl_state.call
failed = results.select { |_, r| r['status'] == 'error' }
result = { 'action' => action, 'results' => results, 'changed' => changed }

if failed.empty?
  puts JSON.generate(result)
else
  first = failed.first
  puts JSON.generate(result.merge('_error' => {
    'kind' => 'ovadm/cert-revoke',
    'msg'  => "puppetserver ca #{action} failed for #{failed.keys.join(', ')}: #{first[1]['detail']}",
  }))
  exit 1
end
RUBY
