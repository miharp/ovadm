# @summary Install a new OpenVox Server deployment
#
# Runs prechecks, configures the package repository, installs openvox-server,
# writes puppet.conf, and waits for the service to become ready.
# When compiler_hosts is provided, installs a Large topology.
#
# @param server_host
#   The primary OpenVox Server node
#
# @param compiler_hosts
#   One or more compiler nodes (Large topology)
#
# @param ovox_version
#   The version of OpenVox Server to install (e.g. '8.3.1'); omit for latest
#
# @param dns_alt_names
#   DNS alternative names to embed in the server certificate.
#   Useful when agents connect via a load balancer hostname or alias.
#   NOTE: dns_alt_names must be configured before the CA certificate is
#   generated on first start. If the service has already run, the SSL
#   directory must be wiped and the service restarted.
#
plan ovadm::install(
  TargetSpec                   $server_host,
  Optional[TargetSpec]         $compiler_hosts = undef,
  Optional[String[1]]          $ovox_version   = undef,
  Optional[Array[String[1]]]   $dns_alt_names  = undef,
) {
  run_plan('ovadm::subplans::precheck', { 'server_host' => $server_host })

  run_plan('ovadm::subplans::install', {
    'server_host'  => $server_host,
    'ovox_version' => $ovox_version,
  })

  run_plan('ovadm::subplans::configure', {
    'server_host'   => $server_host,
    'dns_alt_names' => $dns_alt_names,
  })

  run_command('systemctl enable --now puppetserver', $server_host)

  run_task('ovadm::wait_until_service_ready', $server_host)

  if $compiler_hosts {
    $server_fqdn = run_command('hostname -f', $server_host).first.value['stdout'].strip

    run_plan('ovadm::subplans::precheck', { 'server_host' => $compiler_hosts })

    run_plan('ovadm::subplans::agent_install', {
      'compiler_hosts' => $compiler_hosts,
      'server_fqdn'    => $server_fqdn,
      'ovox_version'   => $ovox_version,
    })

    run_plan('ovadm::subplans::cert_setup', {
      'compiler_hosts' => $compiler_hosts,
      'server_host'    => $server_host,
    })
  }

  out::message('OpenVox Server installation complete.')
}
