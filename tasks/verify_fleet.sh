#!/bin/bash
set -euo pipefail

environment="${PT_environment:-production}"
expected="${PT_expected:-1}"
timeout="${PT_timeout:-90}"
publisher="${PT_publisher:-}"

# Reuse the URL the agents are already polling rather than letting codavox derive
# one from this node's certname. The derived default is correct on a normal node,
# but it depends on the publisher resolving its own FQDN — which is one more thing
# to be true in a container or a split-horizon DNS setup, for no benefit when the
# caller already holds a URL known to work.
args=(compilers --json)
[ -n "$publisher" ] && args+=(--publisher "$publisher")

# Ruby ships with openvox-agent, which every ovadm-managed node has by
# definition. Preferred over python3, which is present on RHEL-family hosts by
# accident of dnf rather than by anything ovadm requires.
ruby=/opt/puppetlabs/puppet/bin/ruby
[ -x "$ruby" ] || ruby=$(command -v ruby || true)
if [ -z "$ruby" ]; then
  printf '{"status":"fail","error":"no ruby found; expected /opt/puppetlabs/puppet/bin/ruby from openvox-agent"}\n'
  exit 1
fi

# Run on the publisher. `codavox compilers` reports what each compiler said it is
# serving, read from that node's own environment symlink — the same one its
# code-id reads. So this verifies the two agree, which is stronger than asking
# each compiler separately: it also proves every compiler authenticated to the
# publisher and is being served.
#
# The wait is on convergence, not on the report. An agent re-reports as soon as
# it converges, so a compiler that has the code appears without waiting for its
# next poll.
count=0
distinct=0
deadline=$(( $(date +%s) + timeout ))
while :; do
  if fleet="$(codavox "${args[@]}" 2>/dev/null)"; then
    # One line per compiler reporting this environment: "<certname> <code_id>".
    # shellcheck disable=SC2016  # single-quoted on purpose: this is Ruby, and
    # $stdin must reach ruby unexpanded.
    reported=$(printf '%s' "$fleet" | "$ruby" -rjson -e '
begin
  fleet = JSON.parse($stdin.read)
rescue JSON::ParserError
  exit 0
end
env = ARGV[0]
fleet.each do |peer|
  id = (peer["serving"] || {})[env]
  puts "#{peer["certname"]} #{id}" if id
end
' "$environment" 2>/dev/null || true)

    count=$(printf '%s' "$reported" | grep -c . || true)
    # Every compiler must be on the same code_id, or the fleet has diverged.
    distinct=$(printf '%s\n' "$reported" | awk 'NF{print $2}' | sort -u | grep -c . || true)

    if [ "$count" -ge "$expected" ] && [ "$distinct" -eq 1 ]; then
      code_id=$(printf '%s\n' "$reported" | awk 'NF{print $2; exit}')
      certnames=$(printf '%s\n' "$reported" | awk 'NF{printf "%s%s", sep, $1; sep=","}')
      printf '{"status":"success","environment":"%s","compilers":%s,"code_id":"%s","certnames":"%s"}\n' \
        "$environment" "$count" "$code_id" "$certnames"
      exit 0
    fi
  fi

  if [ "$(date +%s)" -ge "$deadline" ]; then
    printf '{"status":"fail","error":"expected %s compiler(s) on one code_id for %s within %ss; saw %s reporting %s distinct code_id(s)"}\n' \
      "$expected" "$environment" "$timeout" "$count" "$distinct"
    exit 1
  fi
  sleep 3
done
