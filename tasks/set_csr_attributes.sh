#!/bin/bash
set -euo pipefail

export PATH="/opt/puppetlabs/bin:$PATH"

RUBY='/opt/puppetlabs/puppet/bin/ruby'

# The agent reads the file from its csr_attributes setting, which follows
# confdir. Before the agent is installed the package default applies.
CSR_ATTRS=$(puppet config print csr_attributes --section agent 2>/dev/null || true)
CSR_ATTRS=${CSR_ATTRS:-/etc/puppetlabs/puppet/csr_attributes.yaml}

pp_role="${PT_pp_role}"

# With nothing to keep, write the file directly, so a host without the agent's
# Ruby still gets one. The role is quoted so YAML reads it as a string:
# unquoted, `on` would be read as true and `1.10` as 1.1.
if [ ! -s "$CSR_ATTRS" ]; then
  mkdir -p "$(dirname "$CSR_ATTRS")"
  printf "extension_requests:\n  pp_role: '%s'\n" "$pp_role" > "$CSR_ATTRS"
  printf '{"status":"success","path":"%s","pp_role":"%s","action":"created","kept":[]}\n' \
    "$CSR_ATTRS" "$pp_role"
  exit 0
fi

# An existing file may hold a challengePassword for the CA's autosign policy,
# or extensions of the site's own, so pp_role is merged in rather than the file
# replaced. That needs a YAML parser; without the agent's Ruby the file is
# left alone.
if [ ! -x "$RUBY" ]; then
  printf '{"path":"%s","_error":{"kind":"ovadm/csr-attributes","msg":"%s"}}\n' "$CSR_ATTRS" \
    "${CSR_ATTRS} exists, and merging pp_role into it needs ${RUBY}, which is missing. The file was left as it is."
  exit 1
fi

CSR_ATTRS="$CSR_ATTRS" PP_ROLE="$pp_role" "$RUBY" <<'RUBY'
require 'json'
require 'yaml'

path = ENV['CSR_ATTRS']
role = ENV['PP_ROLE']
# pp_role's registered OID, which a file may use in place of the name
role_oid = '1.3.6.1.4.1.34380.1.1.13'

refuse = lambda do |why|
  msg = "#{path} #{why}. The file was left as it is."
  puts JSON.generate('path' => path, '_error' => { 'kind' => 'ovadm/csr-attributes', 'msg' => msg })
  exit 1
end

# Read the way the agent reads it, with the agent's checks on the top level,
# so a file the agent would reject is reported instead of rewritten.
begin
  attrs = YAML.safe_load(File.read(path, encoding: 'bom|utf-8'),
                         permitted_classes: [Symbol], aliases: true) || {}
rescue Psych::Exception => e
  refuse.call("is not YAML the agent can read (#{e.message})")
end
refuse.call('does not hold a hash') unless attrs.is_a?(Hash)
unexpected = attrs.keys - ['custom_attributes', 'extension_requests']
refuse.call("has keys the agent rejects: #{unexpected.join(', ')}") unless unexpected.empty?
custom   = attrs['custom_attributes'] || {}
requests = attrs['extension_requests'] || {}
refuse.call('has a custom_attributes that is not a hash') unless custom.is_a?(Hash)
refuse.call('has an extension_requests that is not a hash') unless requests.is_a?(Hash)

previous = requests['pp_role'] || requests[role_oid]
merged   = requests.reject { |key, _| key.to_s == role_oid }.merge('pp_role' => role)

result = { 'status' => 'success', 'path' => path, 'pp_role' => role }
if merged == requests
  result['action'] = 'unchanged'
else
  attrs['extension_requests'] = merged
  # Written in place, so the file keeps its owner and mode.
  File.write(path, attrs.to_yaml)
  result['action'] = 'merged'
  result['previous_pp_role'] = previous.to_s unless previous.nil? || previous.to_s == role
end
result['kept'] = custom.keys.map { |key| "custom_attributes.#{key}" } +
                 merged.keys.reject { |key| key == 'pp_role' }.map { |key| "extension_requests.#{key}" }
puts JSON.generate(result)
RUBY
