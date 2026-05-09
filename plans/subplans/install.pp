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
  Optional[String[1]] $ovox_version = undef,
) {
  $ovox_major = $ovox_version ? {
    undef   => 8,
    default => Integer($ovox_version.split('\.')[0]),
  }

  run_task('ovadm::configure_repo', $server_host, { 'ovox_major' => $ovox_major })

  $install_params = $ovox_version ? {
    undef   => {},
    default => { 'version' => $ovox_version },
  }
  run_task('ovadm::install_server', $server_host, $install_params)
}
