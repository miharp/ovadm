#!/bin/bash
set -euo pipefail

puppet='/opt/puppetlabs/bin/puppet'
conf='/etc/puppetlabs/puppetserver/conf.d/versioned-code.conf'

mkdir -p "$(dirname "$conf")"

# Both commands must be set, or neither; OpenVox Server throws at startup if
# exactly one is present.
cat > "$conf" <<'EOF'
versioned-code: {
    code-id-command: /usr/bin/codavox-code-id
    code-content-command: /usr/bin/codavox-code-content
}
EOF

# OpenVox Server reads code from codavox's environment path, and static catalogs
# must be on for the code_id to bind file content.
"$puppet" config set --section main environmentpath /opt/puppetlabs/codavox/environments >&2
"$puppet" config set --section server static_catalogs true >&2

# From codavox 0.7 the agent expires the environment it swapped from this
# server's cache, over DELETE /puppet-admin-api/v1/environment-cache, and treats
# a refused flush as a failed sync. The shipped auth.conf has no rule for that
# path, so add one admitting the compiler's own certificate by its pp_role —
# by OID, because a compiler runs with its CA service disabled and the admin
# API is then authorized with no short-name map, so `pp_role` would match
# nothing. Edited with the hocon gem openvox-agent ships, idempotently.
/opt/puppetlabs/puppet/bin/ruby <<'RUBY'
require 'hocon'
require 'hocon/config_value_factory'
require 'hocon/parser/config_document_factory'

path = '/etc/puppetlabs/puppetserver/conf.d/auth.conf'
rule = {
  'match-request' => {
    'path'   => '/puppet-admin-api/v1/environment-cache',
    'type'   => 'path',
    'method' => 'delete',
  },
  'allow'      => { 'extensions' => { '1.3.6.1.4.1.34380.1.1.13' => 'openvox_compiler' } },
  'sort-order' => 200,
  'name'       => 'codavox environment cache flush',
}
rules = Hocon.load(path)['authorization']['rules']
unless rules.any? { |r| r['name'] == rule['name'] }
  rules << rule
  doc = Hocon::Parser::ConfigDocumentFactory.parse_file(path)
  doc = doc.set_config_value('authorization.rules', Hocon::ConfigValueFactory.from_any_ref(rules))
  File.write(path, doc.render)
end
RUBY

printf '{"status":"success","conf":"%s"}\n' "$conf"
