# @summary Upgrade an existing OpenVox Server deployment
#
# Upgrades within a major version, to a new major version (8 to 9), and from
# Puppet Server to OpenVox (7 to 8). The server is upgraded first, then the
# compilers.
#
# @param server_host
#   The OpenVox Server node
#
# @param ovox_server_version
#   The openvox-server version to upgrade to (e.g. '8.13.0'). Its major version
#   is the one the nodes move to.
#
# @param compiler_hosts
#   Compiler pool nodes to upgrade (Large topology)
#
# @param package_url
#   Direct URL to an openvox-server rpm or deb to install instead of the
#   repository's package
#
# @param ovox_major
#   The OpenVox major version to upgrade to. Defaults to the major version of
#   ovox_server_version; set it when upgrading to a new major from package_url
#   alone.
#
# @param apt_base_url
#   Base URL of an apt mirror to use instead of https://apt.voxpupuli.org, for
#   nodes that move to a new major version's repository
#
# @param yum_base_url
#   Base URL of a yum/dnf mirror to use instead of https://yum.voxpupuli.org,
#   for nodes that move to a new major version's repository
#
plan ovadm::upgrade(
  TargetSpec           $server_host,
  Optional[String[1]]  $ovox_server_version = undef,
  Optional[TargetSpec] $compiler_hosts      = undef,
  Optional[String[1]]  $package_url         = undef,
  Optional[Integer[8]] $ovox_major          = undef,
  Optional[String[1]]  $apt_base_url        = undef,
  Optional[String[1]]  $yum_base_url        = undef,
) {
  unless $ovox_server_version or $package_url {
    fail('Either ovox_server_version or package_url must be provided')
  }

  $version_major = $ovox_server_version ? {
    undef   => undef,
    default => Integer($ovox_server_version.split('\.')[0]),
  }
  if $ovox_major and $version_major and $ovox_major != $version_major {
    fail("ovox_major ${ovox_major} does not match ovox_server_version ${ovox_server_version}")
  }
  $target_major = $ovox_major ? {
    undef   => $version_major,
    default => $ovox_major,
  }

  run_plan('ovadm::subplans::precheck', { 'server_host' => $server_host, 'upgrade' => true, 'ovox_major' => $target_major })

  $node_params = {
    'ovox_server_version' => $ovox_server_version,
    'package_url'         => $package_url,
    'ovox_major'          => $target_major,
    'apt_base_url'        => $apt_base_url,
    'yum_base_url'        => $yum_base_url,
  }

  run_plan('ovadm::subplans::upgrade_server', { 'server_host' => $server_host } + $node_params)

  if $compiler_hosts {
    run_plan('ovadm::subplans::upgrade_compilers', { 'compiler_hosts' => $compiler_hosts } + $node_params)
  }

  out::message('OpenVox Server upgrade complete.')
}
