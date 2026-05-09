# @summary Install a new OpenVox Server deployment
#
# Runs prechecks, configures the package repository, installs openvox-server,
# writes puppet.conf, and waits for the service to become ready.
#
# @param server_host
#   The target node to install OpenVox Server on
#
# @param compiler_hosts
#   One or more compiler nodes to add (Large topology — Phase 5, not yet implemented)
#
# @param ovox_version
#   The version of OpenVox Server to install (e.g. '8.3.1'); omit for latest
#
# @param dns_alt_names
#   DNS alternative names to embed in the server certificate.
#   Useful when agents connect via a load balancer hostname or alias.
#   NOTE: dns_alt_names must be configured before the CA certificate is
#   generated on first start. If the service has already run, the SSL
#   directory must be wiped and the service restarted (Phase 5 concern).
#
plan ovadm::install(
  TargetSpec                   $server_host,
  Optional[TargetSpec]         $compiler_hosts = undef,
  Optional[String[1]]          $ovox_version   = undef,
  Optional[Array[String[1]]]   $dns_alt_names  = undef,
) {
  if $compiler_hosts {
    fail_plan('Large topology (compiler_hosts) is not yet implemented. See Phase 5.')
  }

  run_plan('ovadm::subplans::precheck', { 'server_host' => $server_host })

  # Install packages first so the package manager creates /etc/openvox/
  run_plan('ovadm::subplans::install', {
    'server_host'  => $server_host,
    'ovox_version' => $ovox_version,
  })

  # Configure puppet.conf after install. For Phase 2 this sets certname and
  # server to the system FQDN (matching the defaults). dns_alt_names requires
  # a CA regeneration before the service is started for the first time —
  # a Phase 5 concern when adding compilers.
  run_plan('ovadm::subplans::configure', {
    'server_host'   => $server_host,
    'dns_alt_names' => $dns_alt_names,
  })

  run_task('ovadm::wait_until_service_ready', $server_host)

  out::message('OpenVox Server installation complete.')
}
