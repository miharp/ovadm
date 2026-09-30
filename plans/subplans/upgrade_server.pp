# @summary Upgrade openvox-server on a single node
#
# @api private
#
# Switches the node's package repository when it moves to a new major version,
# installs the target version (upgrading in place, or replacing puppetserver),
# selects a Java the new version supports, restarts the service, waits for it
# to become ready, then reports the installed version.
#
# @param server_host
#   The target node to upgrade
#
# @param ovox_server_version
#   The openvox-server version to upgrade to (e.g. '8.13.0')
#
# @param package_url
#   Direct URL to an openvox-server rpm or deb to install instead of the
#   repository's package. The repository is still configured, for dependencies.
#
# @param ovox_major
#   The OpenVox major version to upgrade to; see ovadm::subplans::upgrade_repo
#
# @param apt_base_url
#   Base URL of an apt mirror to use instead of https://apt.voxpupuli.org
#
# @param yum_base_url
#   Base URL of a yum/dnf mirror to use instead of https://yum.voxpupuli.org
#
plan ovadm::subplans::upgrade_server(
  TargetSpec          $server_host,
  Optional[String[1]] $ovox_server_version = undef,
  Optional[String[1]] $package_url         = undef,
  Optional[Integer]   $ovox_major          = undef,
  Optional[String[1]] $apt_base_url        = undef,
  Optional[String[1]] $yum_base_url        = undef,
) {
  run_plan('ovadm::subplans::upgrade_repo', {
    'targets'      => $server_host,
    'ovox_major'   => $ovox_major,
    'apt_base_url' => $apt_base_url,
    'yum_base_url' => $yum_base_url,
  })

  $install_params = $package_url ? {
    undef   => { 'version' => $ovox_server_version },
    default => { 'package_url' => $package_url },
  }
  run_task('ovadm::install_server', $server_host, $install_params)

  run_task('ovadm::select_java', $server_host)

  run_task('ovadm::service_restart', $server_host)

  run_task('ovadm::wait_until_service_ready', $server_host)

  $installed = run_task('ovadm::get_version', $server_host).first.value['version']
  out::message("Upgraded to ${installed}")
}
