# @summary Upgrade openvox-server on a single node
#
# Installs the target version (upgrading in place), restarts the service,
# waits for it to become ready, then verifies the installed version matches.
#
# @param server_host
#   The target node to upgrade
#
# @param ovox_version
#   The version to upgrade to (e.g. '8.4.0')
#
plan ovadm::subplans::upgrade_server(
  TargetSpec  $server_host,
  String[1]   $ovox_version,
) {
  run_task('ovadm::install_server', $server_host, { 'version' => $ovox_version })

  run_task('ovadm::service_restart', $server_host)

  run_task('ovadm::wait_until_service_ready', $server_host)

  $installed = run_task('ovadm::get_version', $server_host).first.value['version']
  out::message("Upgraded to ${installed}")
}
