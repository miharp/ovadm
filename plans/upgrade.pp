# @summary Upgrade an existing OpenVox Server deployment
#
# Upgrades within a major version, to a new major version (8 to 9), and from
# Puppet Server to OpenVox (7 to 8). The server is upgraded first, then the
# compilers: all at once, or one at a time with `rolling`.
#
# The Puppet agent on the server and on every compiler named is disabled for
# the whole upgrade (`puppet agent --disable`, after waiting for a run under
# way to finish) and enabled again at the end, whether the upgrade succeeded
# or not, so a scheduled run cannot apply the site's code to a server in the
# middle of it. An agent that was already disabled stays disabled.
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
# @param rolling
#   Upgrade the compilers one at a time, in the order given in
#   `compiler_hosts`, waiting for each to answer again before starting the
#   next, so the rest of the pool keeps compiling. A compiler that fails
#   stops the plan and the ones after it are left on the version they had.
#   By default the compilers are upgraded, and restart, all at once. Has no
#   effect without `compiler_hosts`.
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
# @param skip_backup
#   Do not take a backup of the server before touching packages. The
#   backup is `ovadm::backup` with its defaults: the CA, the certificates,
#   the configuration and the code record, verified, under
#   `backup_destination`. It is the way back if the upgrade goes wrong.
#
# @param backup_destination
#   Directory on the server for the pre-upgrade archive
#
# @param backup_extra_paths
#   Paths outside `/etc/puppetlabs/` to include in the pre-upgrade archive,
#   as `extra_paths` on `ovadm::backup`
#
# @return
#   `backup`, the pre-upgrade archive path per target name, or empty with
#   `skip_backup`; `agents_held`, the names of the targets whose agent the
#   plan disabled and enabled again
#
plan ovadm::upgrade(
  TargetSpec           $server_host,
  Optional[String[1]]  $ovox_server_version = undef,
  Optional[TargetSpec] $compiler_hosts      = undef,
  Boolean              $rolling             = false,
  Optional[String[1]]  $package_url         = undef,
  Optional[Integer[8]] $ovox_major          = undef,
  Optional[String[1]]  $apt_base_url        = undef,
  Optional[String[1]]  $yum_base_url        = undef,
  Boolean              $skip_backup         = false,
  String[1]            $backup_destination  = '/var/backups/openvox',
  Array[String[1]]     $backup_extra_paths  = [],
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

  # Keep the agents out of the way from here to the end, on every server at
  # once: a scheduled run in the middle would apply whatever the site's code
  # pins, moving a package back, or a compiler ahead of the server. An agent
  # the operator disabled is left alone; one an interrupted run of this plan
  # left disabled is taken over and enabled at the end.
  $all_targets = $compiler_hosts ? {
    undef   => get_targets($server_host),
    default => get_targets($server_host) + get_targets($compiler_hosts),
  }
  $lock_prefix = 'ovadm upgrade'
  $lock_message = $ovox_server_version ? {
    undef   => "${lock_prefix} in progress",
    default => "${lock_prefix} to ${ovox_server_version} in progress",
  }
  $disabled = run_task('ovadm::agent_disable', $all_targets, {
    'message'       => $lock_message,
    'reclaim'       => $lock_prefix,
    '_catch_errors' => true,
  })
  $held = $disabled.ok_set.filter_set |$r| { $r.value['disabled_here'] }.targets
  $disabled.ok_set.filter_set |$r| { $r.value['status'] == 'already_disabled' }.each |$r| {
    out::message("${r.target.name}: the agent was already disabled (${r.value['message']}); it stays disabled after the upgrade.")
  }

  unless $disabled.ok {
    unless $held.empty {
      run_task('ovadm::agent_enable', $held, { 'only_message' => $lock_prefix, '_catch_errors' => true })
    }
    $why = $disabled.error_set.map |$r| { "${r.target.name}: ${r.error.msg}" }.join('; ')
    fail_plan("Could not disable the agent, so nothing was upgraded. ${why}", 'ovadm/upgrade')
  }

  $outcome = catch_errors() || {
    # The way back, taken before anything changes: the CA, certificates,
    # configuration and code record of the server, verified. Compilers hold
    # nothing unique and are left out.
    $archives = $skip_backup ? {
      true    => {},
      default => run_plan('ovadm::backup', {
        'server_host' => $server_host,
        'destination' => $backup_destination,
        'extra_paths' => $backup_extra_paths,
      })['archives'],
    }
    $archives.each |$host, $path| {
      out::message("Pre-upgrade backup of ${host}: ${path}. Copy it off the host; it is the way back if this upgrade goes wrong.")
    }

    $node_params = {
      'ovox_server_version' => $ovox_server_version,
      'package_url'         => $package_url,
      'ovox_major'          => $target_major,
      'apt_base_url'        => $apt_base_url,
      'yum_base_url'        => $yum_base_url,
    }

    run_plan('ovadm::subplans::upgrade_server', { 'server_host' => $server_host } + $node_params)

    if $compiler_hosts {
      run_plan('ovadm::subplans::upgrade_compilers', {
        'compiler_hosts' => $compiler_hosts,
        'rolling'        => $rolling,
      } + $node_params)
    }

    $archives
  }

  # Enable the agents this run disabled, on the failure path as well: a
  # failed upgrade must not leave Puppet switched off without saying so.
  unless $held.empty {
    $enabled = run_task('ovadm::agent_enable', $held, { 'only_message' => $lock_prefix, '_catch_errors' => true })
    $enabled.ok_set.filter_set |$r| { $r.value['status'] == 'left_disabled' }.each |$r| {
      out::message("${r.target.name}: the agent was disabled again during the upgrade (${r.value['message']}); it stays disabled.")
    }
    unless $enabled.ok {
      out::message("Could not enable the agent again on ${enabled.error_set.names.join(', ')}. Run 'puppet agent --enable' there.")
    }
  }

  if $outcome =~ Error {
    out::message('The upgrade failed. The agents this plan disabled are enabled again, unless a line above names a host where that failed.')
    fail_plan($outcome)
  }

  out::message('OpenVox Server upgrade complete.')

  return({ 'backup' => $outcome, 'agents_held' => $held.map |$t| { $t.name } })
}
