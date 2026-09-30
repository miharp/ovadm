# @summary Upgrade openvox-server on compiler pool nodes
#
# @api private
#
# @param compiler_hosts
#   The compiler node(s) to upgrade
#
# @param ovox_server_version
#   The openvox-server version to upgrade to (e.g. '8.13.0')
#
# @param package_url
#   Direct URL to an openvox-server rpm or deb to install instead of the
#   repository's package
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
plan ovadm::subplans::upgrade_compilers(
  TargetSpec          $compiler_hosts,
  Optional[String[1]] $ovox_server_version = undef,
  Optional[String[1]] $package_url         = undef,
  Optional[Integer]   $ovox_major          = undef,
  Optional[String[1]] $apt_base_url        = undef,
  Optional[String[1]] $yum_base_url        = undef,
) {
  run_plan('ovadm::subplans::upgrade_repo', {
    'targets'      => $compiler_hosts,
    'ovox_major'   => $ovox_major,
    'apt_base_url' => $apt_base_url,
    'yum_base_url' => $yum_base_url,
  })

  $install_params = $package_url ? {
    undef   => { 'version' => $ovox_server_version },
    default => { 'package_url' => $package_url },
  }
  run_task('ovadm::install_server', $compiler_hosts, $install_params)

  run_task('ovadm::select_java', $compiler_hosts)

  run_task('ovadm::service_restart', $compiler_hosts)
  run_task('ovadm::wait_until_service_ready', $compiler_hosts)
}
