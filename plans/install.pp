# @summary Install a new OpenVox Server deployment
#
# @param server_host
#   The target node to install OpenVox Server on
#
# @param compiler_hosts
#   One or more compiler nodes to add (Large topology only)
#
# @param ovox_version
#   The version of OpenVox Server to install
#
# @param dns_alt_names
#   A list of DNS alternative names to add to the OpenVox Server certificate
#
plan ovadm::install(
  TargetSpec                   $server_host,
  Optional[TargetSpec]         $compiler_hosts = undef,
  Optional[String[1]]          $ovox_version   = undef,
  Optional[Array[String[1]]]   $dns_alt_names  = undef,
) {

  out::message('ovadm::install is not yet implemented. Contributions welcome!')

  # Future implementation outline:
  #   1. Verify target connectivity
  #   2. Download OpenVox Server package for target platform
  #   3. Run installer
  #   4. Configure OpenVox Server (puppet.conf, auth.conf, etc.)
  #   5. Start services and validate

}
