# @summary Upgrade openvox-server on compiler pool nodes
#
# @param compiler_hosts
#   The compiler node(s) to upgrade
#
# @param ovox_version
#   The version to upgrade to
#
plan ovadm::subplans::upgrade_compilers(
  TargetSpec $compiler_hosts,
  String[1]  $ovox_version,
) {
  run_task('ovadm::install_server', $compiler_hosts, { 'version' => $ovox_version })
  run_task('ovadm::service_restart', $compiler_hosts)
  run_task('ovadm::wait_until_service_ready', $compiler_hosts)
}
