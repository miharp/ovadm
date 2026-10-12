# @summary Configure puppet.conf on an OpenVox Server node
#
# @api private
#
# @param server_host
#   The target node to configure
#
# @param certname
#   Certificate name; defaults to the system FQDN
#
# @param dns_alt_names
#   DNS alternative names to embed in the server certificate.
#   Written to puppet.conf so later certificate regeneration picks them up;
#   ovadm::install also passes them to `puppetserver ca setup`, which is what
#   puts them on the server certificate created at install time.
#
# @param environment
#   Puppet environment the server's own agent asks for; omit for the default
#
plan ovadm::subplans::configure(
  TargetSpec                 $server_host,
  Optional[String[1]]        $certname      = undef,
  Optional[Array[String[1]]] $dns_alt_names = undef,
  Optional[String[1]]        $environment   = undef,
) {
  $params = {}
  $p1 = $certname ? {
    undef   => $params,
    default => $params + { 'certname' => $certname },
  }
  $p2 = $dns_alt_names ? {
    undef   => $p1,
    default => $p1 + { 'dns_alt_names' => $dns_alt_names.join(',') },
  }
  $p3 = $environment ? {
    undef   => $p2,
    default => $p2 + { 'environment' => $environment },
  }
  run_task('ovadm::configure_puppet_conf', $server_host, $p3)
}
