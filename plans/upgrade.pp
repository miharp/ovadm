# @summary Upgrade an existing OpenVox Server deployment
#
# @param server_host
#   The OpenVox Server node
#
# @param ovox_server_version
#   The openvox-server version to upgrade to (e.g. '8.13.0')
#
# @param compiler_hosts
#   Compiler pool nodes to upgrade (Large topology)
#
plan ovadm::upgrade(
  TargetSpec           $server_host,
  String[1]            $ovox_server_version,
  Optional[TargetSpec] $compiler_hosts = undef,
) {
  run_plan('ovadm::subplans::precheck', { 'server_host' => $server_host })

  run_plan('ovadm::subplans::upgrade_server', {
    'server_host'         => $server_host,
    'ovox_server_version' => $ovox_server_version,
  })

  if $compiler_hosts {
    run_plan('ovadm::subplans::upgrade_compilers', {
      'compiler_hosts'      => $compiler_hosts,
      'ovox_server_version' => $ovox_server_version,
    })
  }

  out::message('OpenVox Server upgrade complete.')
}
