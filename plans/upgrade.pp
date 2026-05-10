# @summary Upgrade an existing OpenVox Server deployment
#
# @param server_host
#   The OpenVox Server node
#
# @param ovox_version
#   The version to upgrade to (e.g. '8.4.0')
#
# @param compiler_hosts
#   Compiler pool nodes to upgrade (Large topology)
#
plan ovadm::upgrade(
  TargetSpec           $server_host,
  String[1]            $ovox_version,
  Optional[TargetSpec] $compiler_hosts = undef,
) {
  run_plan('ovadm::subplans::precheck', { 'server_host' => $server_host })

  run_plan('ovadm::subplans::upgrade_server', {
    'server_host'  => $server_host,
    'ovox_version' => $ovox_version,
  })

  if $compiler_hosts {
    run_plan('ovadm::subplans::upgrade_compilers', {
      'compiler_hosts' => $compiler_hosts,
      'ovox_version'   => $ovox_version,
    })
  }

  out::message('OpenVox Server upgrade complete.')
}
