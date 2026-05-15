# @summary Upgrade openvox-server on compiler pool nodes
#
# @param compiler_hosts
#   The compiler node(s) to upgrade
#
# @param ovox_server_version
#   The openvox-server version to upgrade to (e.g. '8.13.0')
#
plan ovadm::subplans::upgrade_compilers(
  TargetSpec $compiler_hosts,
  String[1]  $ovox_server_version,
) {
  run_task('ovadm::install_server', $compiler_hosts, { 'version' => $ovox_server_version })

  run_task('ovadm::service_restart', $compiler_hosts)
  run_task('ovadm::wait_until_service_ready', $compiler_hosts)
}
