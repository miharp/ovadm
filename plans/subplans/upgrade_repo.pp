# @summary Move nodes to the package repository of the major version they are upgraded to
#
# @api private
#
# Checks what each node runs. A node on an older major version, or still on
# Puppet Server rather than OpenVox, gets the target major's release package in
# place of its old one. A node already on the target major is left alone, so a
# minor upgrade, or a re-run after an upgrade that failed partway, changes no
# repositories.
#
# @param targets
#   The nodes about to be upgraded
#
# @param ovox_major
#   The OpenVox major version they are upgraded to. When unset, the nodes stay
#   on their current repository and must already run openvox-server.
#
# @param apt_base_url
#   Base URL of an apt mirror to use instead of https://apt.voxpupuli.org
#
# @param yum_base_url
#   Base URL of a yum/dnf mirror to use instead of https://yum.voxpupuli.org
#
# @return The nodes whose repository was switched
#
plan ovadm::subplans::upgrade_repo(
  TargetSpec          $targets,
  Optional[Integer]   $ovox_major   = undef,
  Optional[String[1]] $apt_base_url = undef,
  Optional[String[1]] $yum_base_url = undef,
) {
  $versions = run_task('ovadm::get_version', $targets)

  $behind = $versions.filter |$result| {
    $name    = $result.target.name
    $version = $result.value['version']
    $package = $result.value['package']

    if $version == 'not_installed' {
      fail_plan("Neither openvox-server nor puppetserver is installed on ${name}; use ovadm::install")
    }

    $major = Integer($version.split('\.')[0])

    if $ovox_major == undef {
      if $package != 'openvox-server' {
        fail_plan("${name} runs ${package} ${version}; set ovox_server_version or ovox_major to upgrade it to OpenVox")
      }
      false
    } elsif $major > $ovox_major {
      fail_plan("${name} runs ${package} ${version}, newer than OpenVox ${ovox_major}; ovadm does not downgrade")
    } elsif $major < $ovox_major - 1 {
      fail_plan("${name} runs ${package} ${version}; upgrade one major version at a time, to ${$major + 1} first")
    } else {
      $major < $ovox_major or $package != 'openvox-server'
    }
  }.map |$result| { $result.target }

  unless $behind.empty {
    $repo_params = {
      'ovox_major'   => $ovox_major,
      'apt_base_url' => $apt_base_url,
      'yum_base_url' => $yum_base_url,
    }.filter |$key, $value| { $value =~ NotUndef }

    run_task('ovadm::configure_repo', $behind, $repo_params)
    out::message("Switched to the OpenVox ${ovox_major} repository: ${behind.map |$t| { $t.name }.join(', ')}")
  }

  return $behind
}
