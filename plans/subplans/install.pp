# @summary Install OpenVox Server packages on a target
#
# Configures the OpenVox package repository and installs the openvox-server
# package. The service is left in whatever state the package manager puts it —
# typically auto-started on Debian systems.
#
# @param server_host
#   The target node to install on
#
# @param ovox_version
#   Specific version to install (e.g. '8.3.1'); omit for latest
#
plan ovadm::subplans::install(
  TargetSpec          $server_host,
  Optional[String[1]] $ovox_version  = undef,
  Optional[String[1]] $apt_base_url  = undef,
  Optional[String[1]] $yum_base_url  = undef,
) {
  $ovox_major = $ovox_version ? {
    undef   => 8,
    default => Integer($ovox_version.split('\.')[0]),
  }

  $repo_params_1 = { 'ovox_major' => $ovox_major }
  $repo_params_2 = $apt_base_url ? {
    undef   => $repo_params_1,
    default => $repo_params_1 + { 'apt_base_url' => $apt_base_url },
  }
  $repo_params = $yum_base_url ? {
    undef   => $repo_params_2,
    default => $repo_params_2 + { 'yum_base_url' => $yum_base_url },
  }
  run_task('ovadm::configure_repo', $server_host, $repo_params)

  $install_params = $ovox_version ? {
    undef   => {},
    default => { 'version' => $ovox_version },
  }
  run_task('ovadm::install_server', $server_host, $install_params)
}
