# @summary Install OpenVox Server on compiler hosts and configure them to use
#          the server as their CA
#
# @param compiler_hosts
#   The compiler node(s) to set up
#
# @param server_fqdn
#   FQDN of the server (used for puppet.conf server and ca_server)
#
# @param ovox_version
#   Specific version to install; omit for latest
#
plan ovadm::subplans::agent_install(
  TargetSpec          $compiler_hosts,
  String[1]           $server_fqdn,
  Optional[String[1]] $ovox_version = undef,
  Optional[String[1]] $apt_base_url = undef,
  Optional[String[1]] $yum_base_url = undef,
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
  run_task('ovadm::configure_repo', $compiler_hosts, $repo_params)

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
