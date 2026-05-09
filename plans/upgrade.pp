# @summary Upgrade an existing OpenVox Server deployment
#
# @param server_host
#   The target node running OpenVox Server
#
# @param ovox_version
#   The version to upgrade to (e.g. '8.4.0')
#
# @param compiler_hosts
#   Compiler pool nodes to upgrade (Large topology — Phase 5, not yet implemented)
#
plan ovadm::upgrade(
  TargetSpec           $server_host,
  String[1]            $ovox_version,
  Optional[TargetSpec] $compiler_hosts = undef,
) {
  if $compiler_hosts {
    fail_plan('Large topology upgrade (compiler_hosts) is not yet implemented. See Phase 5.')
  }

  run_plan('ovadm::subplans::precheck', { 'server_host' => $server_host })

  run_plan('ovadm::subplans::upgrade_server', {
    'server_host'  => $server_host,
    'ovox_version' => $ovox_version,
  })

  out::message('OpenVox Server upgrade complete.')
}
