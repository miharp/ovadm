#!/bin/bash
set -euo pipefail

CA_CONF='/etc/puppetlabs/puppetserver/conf.d/ca.conf'

allow="${PT_allow_auto_renewal}"
ttl="${PT_auto_renewal_cert_ttl:-}"

[ -f "$CA_CONF" ] || printf 'certificate-authority: {\n}\n' > "$CA_CONF"

# Edit via the hocon gem (ConfigDocument preserves comments and formatting)
CA_CONF="$CA_CONF" ALLOW="$allow" TTL="$ttl" \
  /opt/puppetlabs/puppet/bin/ruby <<'RUBY'
require 'hocon/parser/config_document_factory'

path = ENV['CA_CONF']
doc = Hocon::Parser::ConfigDocumentFactory.parse_file(path)
doc = doc.set_value('certificate-authority.allow-auto-renewal', ENV['ALLOW'])
unless ENV['TTL'].to_s.empty?
  doc = doc.set_value('certificate-authority.auto-renewal-cert-ttl', %("#{ENV['TTL']}"))
end
File.write(path, doc.render)
RUBY

if [ -n "$ttl" ]; then
  printf '{"status":"success","path":"%s","allow_auto_renewal":%s,"auto_renewal_cert_ttl":"%s"}\n' \
    "$CA_CONF" "$allow" "$ttl"
else
  printf '{"status":"success","path":"%s","allow_auto_renewal":%s}\n' \
    "$CA_CONF" "$allow"
fi
