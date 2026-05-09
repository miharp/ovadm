# @summary Configure puppet.conf on an OpenVox Server node
#
# @param server_host
#   The target node to configure
#
# @param certname
#   Certificate name; defaults to the system FQDN
#
# @param dns_alt_names
#   DNS alternative names to embed in the server certificate.
#   Must be set before the CA certificate is generated (i.e. before first
#   service start). If the service has already started, the SSL directory
#   must be wiped and the service restarted for this to take effect.
#
plan ovadm::subplans::configure(
  TargetSpec                 $server_host,
  Optional[String[1]]        $certname      = undef,
  Optional[Array[String[1]]] $dns_alt_names = undef,
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
  run_task('ovadm::configure_puppet_conf', $server_host, $p2)
}
