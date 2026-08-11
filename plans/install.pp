# @summary Install a new OpenVox Server deployment
#
# Runs prechecks, configures the package repository, installs openvox-server,
# writes puppet.conf, and waits for the service to become ready.
# When compiler_hosts is provided, installs a Large topology.
#
# @param server_host
#   The OpenVox Server node
#
# @param compiler_hosts
#   One or more compiler nodes (Large topology)
#
# @param ovox_version
#   OpenVox Agent version (e.g. '8.26.2'); determines which major repo to enable
#
# @param ovox_server_version
#   Specific openvox-server version to install (e.g. '8.13.0'); omit for latest
#
# @param dns_alt_names
#   DNS alternative names to embed in the server certificate.
#   Useful when agents connect via a load balancer hostname or alias.
#   NOTE: dns_alt_names must be configured before the CA certificate is
#   generated on first start. If the service has already run, the SSL
#   directory must be wiped and the service restarted.
#
# @param enable_cert_auto_renewal
#   Enable certificate auto-renewal on the CA (allow-auto-renewal in
#   ca.conf) before first service start, so every certificate the CA signs
#   is short-lived and renewed automatically during agent runs.
#   NOTE: renewal only happens when agents run regularly (service, cron,
#   or scheduled runs) — ovadm does not set that up. Nodes that stop
#   checking in are left with an expired certificate once the short TTL
#   elapses. Compilers additionally need a puppetserver restart to serve
#   a renewed certificate. Defaults to false, matching upstream.
#
# @param auto_renewal_cert_ttl
#   TTL for auto-renewed certificates (e.g. '60d', '90d'). Only used when
#   enable_cert_auto_renewal is true; omit to keep the packaged default.
#
plan ovadm::install(
  TargetSpec                   $server_host,
  Optional[TargetSpec]         $compiler_hosts           = undef,
  Optional[String[1]]          $ovox_version             = undef,
  Optional[String[1]]          $ovox_server_version      = undef,
  Optional[Array[String[1]]]   $dns_alt_names            = undef,
  Optional[String[1]]          $apt_base_url             = undef,
  Optional[String[1]]          $yum_base_url             = undef,
  Optional[String[1]]          $package_url              = undef,
  Boolean                      $enable_cert_auto_renewal = false,
  Optional[String[1]]          $auto_renewal_cert_ttl    = undef,
) {
  run_plan('ovadm::subplans::precheck', { 'server_host' => $server_host })

  run_plan('ovadm::subplans::install', {
    'server_host'         => $server_host,
    'ovox_version'        => $ovox_version,
    'ovox_server_version' => $ovox_server_version,
    'apt_base_url'        => $apt_base_url,
    'yum_base_url'        => $yum_base_url,
    'package_url'         => $package_url,
  })

  run_plan('ovadm::subplans::configure', {
    'server_host'   => $server_host,
    'dns_alt_names' => $dns_alt_names,
  })

  # csr_attributes.yaml must be written before first start — puppetserver reads
  # it when generating its own certificate on initial startup
  run_task('ovadm::set_csr_attributes', $server_host, { 'pp_role' => 'openvox_server' })

  # ca.conf must be in place before first start so even the compilers'
  # initial certificates are issued with the auto-renewal TTL
  if $enable_cert_auto_renewal {
    $renewal_params = $auto_renewal_cert_ttl ? {
      undef   => { 'allow_auto_renewal' => true },
      default => { 'allow_auto_renewal' => true, 'auto_renewal_cert_ttl' => $auto_renewal_cert_ttl },
    }
    run_task('ovadm::configure_ca_renewal', $server_host, $renewal_params)
  }

  run_command('systemctl enable --now puppetserver', $server_host)

  run_task('ovadm::wait_until_service_ready', $server_host)

  if $compiler_hosts {
    $server_fqdn = run_command('hostname -f', $server_host).first.value['stdout'].strip

    run_plan('ovadm::subplans::precheck', { 'server_host' => $compiler_hosts })

    run_plan('ovadm::subplans::agent_install', {
      'compiler_hosts'      => $compiler_hosts,
      'server_fqdn'         => $server_fqdn,
      'ovox_version'        => $ovox_version,
      'ovox_server_version' => $ovox_server_version,
      'apt_base_url'        => $apt_base_url,
      'yum_base_url'        => $yum_base_url,
      'package_url'         => $package_url,
    })

    run_plan('ovadm::subplans::cert_setup', {
      'compiler_hosts' => $compiler_hosts,
      'server_host'    => $server_host,
    })

    run_task('ovadm::configure_compiler_ssl', $compiler_hosts)

    run_command('systemctl enable --now puppetserver', $compiler_hosts)
  }

  out::message('OpenVox Server installation complete.')
}
