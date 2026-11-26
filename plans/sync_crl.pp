# @summary Bring the CRL on compilers and other hosts up to date with the CA's
#
# Reads the CRLs from the CA directory on the server and installs them on the
# hosts named. Nothing is restarted and no agent is run.
#
# The server applies a revocation within a second. A compiler checks
# clients against the copy of the CRL the Puppet agent on the same host
# keeps, which only an agent run refreshes, and only once that copy is a day
# old (`crl_refresh_interval`). Until then the compiler goes on serving the
# revoked host. Run this plan after a revocation made with `puppetserver ca
# revoke` or `puppetserver ca clean`; `ovadm::revoke` does both steps.
#
# Agents fetch the CRL themselves within a day, so they are named only when
# they cannot: a host whose copy has run out refuses the server it would
# fetch a new one from.
#
# @param server_host
#   The OpenVox Server node that is the CA
#
# @param compiler_hosts
#   Compiler pool nodes (Large topology). The plan warns when the server
#   knows of a compiler that is not among the hosts named.
#
# @param agent_hosts
#   Other hosts to install the CRLs on: agents whose copy has run out, and
#   anything else that keeps a copy of its own. The server and the compilers
#   may be among them, as when a group names every host.
#
# @return
#   `crls`, the CRLs installed (issuer, CRL number, revoked count, next
#   update); `synced`, per target name what happened to its copy (`updated`,
#   `unchanged`, `kept_newer` or `absent`); `failed`, per target name why its
#   CRLs were not installed; `host_cert_revoked`, the targets whose own
#   certificate is on the CRL; `compilers_not_named`, the compilers the
#   server knows of that did not get it.
#
plan ovadm::sync_crl(
  TargetSpec           $server_host,
  Optional[TargetSpec] $compiler_hosts = undef,
  Optional[TargetSpec] $agent_hosts    = undef,
) {
  $servers = get_targets($server_host)
  unless $servers.length == 1 {
    fail_plan("server_host must name one host, the CA; it names ${servers.length}", 'ovadm/sync-crl')
  }
  $server = $servers[0]

  # The server copies the CA's CRL to its own hostcrl by itself, so it is
  # left out; every other host once.
  $named = [$compiler_hosts, $agent_hosts].filter |$spec| { $spec != undef }.map |$spec| { get_targets($spec) }.flatten
  $hosts = $named.reduce([]) |$memo, $t| {
    $seen = $memo.map |$m| { $m.name }
    if $t.name == $server.name or $t.name in $seen {
      $memo
    } else {
      $memo + [$t]
    }
  }
  if $hosts.empty {
    fail_plan('Name the hosts to install the CRL on in compiler_hosts or agent_hosts. The server itself needs nothing: it reloads its own CRL on every revocation.', 'ovadm/sync-crl')
  }

  $result = run_plan('ovadm::subplans::crl_sync', { 'server_host' => $server, 'hosts' => $hosts })

  unless $result['failed'].empty {
    fail_plan(
      "The CRL of ${server.name} was not installed on ${result['failed'].keys.join(', ')}. Run the plan again for those hosts.",
      'ovadm/sync-crl',
      $result,
    )
  }

  out::message("CRL of ${server.name} installed on ${result['synced'].length} host(s).")
  return($result)
}
