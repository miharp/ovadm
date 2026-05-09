# @summary Install OpenVox Server on compiler hosts and configure them to use
#          the primary as their CA
#
# @param compiler_hosts
#   The compiler node(s) to set up
#
# @param server_fqdn
#   FQDN of the primary server (used for puppet.conf server and ca_server)
#
# @param ovox_version
#   Specific version to install; omit for latest
#
plan ovadm::subplans::agent_install(
  TargetSpec          $compiler_hosts,
  String[1]           $server_fqdn,
  Optional[String[1]] $ovox_version = undef,
) {
  $ovox_major = $ovox_version ? {
    undef   => 8,
    default => Integer($ovox_version.split('\.')[0]),
  }

  run_task('ovadm::configure_repo', $compiler_hosts, { 'ovox_major' => $ovox_major })

  $install_params = $ovox_version ? {
    undef   => {},
    default => { 'version' => $ovox_version },
  }
  run_task('ovadm::install_server', $compiler_hosts, $install_params)

  run_task('ovadm::configure_puppet_conf', $compiler_hosts, {
    'server'    => $server_fqdn,
    'ca_server' => $server_fqdn,
  })
}
