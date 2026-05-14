# @summary Add one or more compiler nodes to an existing OpenVox Server deployment
#
# @param server_host
#   The OpenVox Server (acts as CA)
#
# @param compiler_hosts
#   The compiler node(s) to install and enroll
#
# @param ovox_version
#   Specific version to install on the compilers; omit for latest
#
plan ovadm::add_compiler(
  TargetSpec          $server_host,
  TargetSpec          $compiler_hosts,
  Optional[String[1]] $ovox_version = undef,
  Optional[String[1]] $apt_base_url = undef,
  Optional[String[1]] $yum_base_url = undef,
) {
  run_plan('ovadm::subplans::precheck', { 'server_host' => $compiler_hosts })

  $server_fqdn = run_command('hostname -f', $server_host).first.value['stdout'].strip

  run_plan('ovadm::subplans::agent_install', {
    'compiler_hosts' => $compiler_hosts,
    'server_fqdn'    => $server_fqdn,
    'ovox_version'   => $ovox_version,
    'apt_base_url'   => $apt_base_url,
    'yum_base_url'   => $yum_base_url,
  })

  run_plan('ovadm::subplans::cert_setup', {
    'compiler_hosts' => $compiler_hosts,
    'server_host'    => $server_host,
  })

  run_task('ovadm::configure_compiler_ssl', $compiler_hosts)

  run_command('systemctl enable --now puppetserver', $compiler_hosts)

  out::message('Compiler(s) added to the pool.')
}
