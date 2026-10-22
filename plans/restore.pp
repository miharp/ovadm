# @summary Restore an OpenVox primary server from an `ovadm::backup` archive
#
# Puts the files of the archive back on the host they came from, with the
# services stopped for the copy, then starts puppetserver, redeploys the code
# when it is in scope, runs the agent once so the site's own code converges,
# and reports the status. The archive is checked first: its checksums, that
# it is from this host, that the openvox-server version matches, and, when
# the CA is in scope, that the CA on the host has signed nothing since the
# backup. Each check stops the plan unless `force` is set.
#
# Files added since the backup stay. On a host the openvox_server module
# manages, the files it owns come back on the next agent run: roll those
# back in Hiera, and use this plan for the rest.
#
# On a rebuilt host, run `ovadm::install` first with the versions the
# manifest names (the plan prints the exact command when the server is not
# installed), then this plan with `rebuild`. That restores everything but
# `puppet.conf`, `puppetdb.conf` and `routes.yaml` first and runs the agent
# on a server that has no OpenVoxDB wiring yet, as on the original build,
# so the site's code can bring OpenVoxDB back; then it puts the
# configuration back whole, with `openvoxdb-termini` installed when the
# host still lacks it.
#
# @param server_host
#   The OpenVox Server node
#
# @param archive
#   Path of the archive on the server
#
# @param source
#   Path of the archive on the workstation running Bolt. It is uploaded to
#   `archive` on the server before anything else: the rebuilt-server path,
#   where the archive is wherever the backups were kept.
#
# @param scope
#   What to put back: `ca`, `config`, `code` (what the archive holds under
#   `/etc/puppetlabs/code/` and `/etc/puppetlabs/r10k/`, followed by an r10k
#   deploy), `extra` (the paths given as `extra_paths` at backup time).
#   Default: everything the archive holds.
#
# @param rebuild
#   The host was rebuilt: leave the files that wire the server to OpenVoxDB
#   out of the first pass, run the agent so the site's code brings back
#   what it installs, then put the configuration back whole.
#
# @param force
#   Restore even when the archive is from another certname or
#   openvox-server version, or the host's CA has signed certificates since
#   the backup; those certificates must then be cleaned and re-signed.
#
# @param dry_run
#   Report which files would change and stop; nothing is written and no
#   service is touched.
#
# @param age_identity
#   Path of the age identity file on the server, for a `.tar.gz.age` archive.
#
# @param deploy_code
#   With `code` in scope, run `r10k deploy environment --modules` after the
#   files are back, when r10k is installed.
#
# @param agent_run
#   Run the agent once on the server after the restore, so the site's code
#   brings back what it owns. A failed run is reported, not fatal: the files
#   are back and the services are up by then.
#
# @return
#   `verify`, `restore` and `agent` results from the tasks, and `status`
#   from `ovadm::status`; with `dry_run`, `verify` and `restore` only. With
#   `rebuild`, `restore` and `agent` are arrays, one entry per pass.
#
plan ovadm::restore(
  TargetSpec                                                $server_host,
  String[1]                                                 $archive,
  Optional[String[1]]                                       $source       = undef,
  Optional[Array[Enum['ca', 'config', 'code', 'extra'], 1]] $scope        = undef,
  Boolean                                                   $rebuild      = false,
  Boolean                                                   $force        = false,
  Boolean                                                   $dry_run      = false,
  Optional[String[1]]                                       $age_identity = undef,
  Boolean                                                   $deploy_code  = true,
  Boolean                                                   $agent_run    = true,
) {
  $target = get_targets($server_host)[0]
  $name   = $target.name

  if $source {
    # A rebuilt host has no backup directory yet.
    $archive_dir = $archive.regsubst('/[^/]+$', '')
    run_command("install -d -m 0700 '${archive_dir}'", $target)
    upload_file($source, $archive, $target)
    out::message("${name}: uploaded ${source} to ${archive}")
  }

  $age = $age_identity ? {
    undef   => {},
    default => { 'age_identity' => $age_identity },
  }

  # The archive itself, and what it says against the host.
  $verify = run_task('ovadm::backup_verify', $target, { 'archive' => $archive } + $age).first.value
  $verify['problems'].each |$p| { out::message("ERROR ${name}: ${p}") }
  $verify['warnings'].each |$w| { out::message("WARNING ${name}: ${w}") }
  if $verify['status'] != 'ok' {
    $hard = $verify['problems'].filter |$p| { $p !~ /^the archive is from / }
    if !$hard.empty or !$force {
      fail_plan("${archive} on ${name} did not verify: ${verify['problems'].join('; ')}", 'ovadm/restore')
    }
  }
  out::message("${name}: ${archive} verified, ${verify['checksums']['checked']} checksums, from ${verify['certname']} on ${verify['created']}")

  $termini = $verify['host'] ? {
    undef   => undef,
    default => $verify['host']['packages']['openvoxdb-termini'],
  }
  $termini_missing = ($termini != undef and $termini['archive'] != undef and $termini['host'] == undef)

  $pass = {
    'target'       => $target,
    'archive'      => $archive,
    'force'        => $force,
    'dry_run'      => $dry_run,
    'age_identity' => $age_identity,
    'deploy_code'  => $deploy_code,
    'agent_run'    => $agent_run,
  }

  if $dry_run {
    $one = run_plan('ovadm::subplans::restore_pass', $pass + { 'scope' => $scope })
    return({ 'verify' => $verify, 'restore' => $one['restore'] })
  }

  if $rebuild {
    $wanted = $scope ? {
      undef   => ['ca', 'config', 'code', 'extra'],
      default => $scope,
    }
    # Pass 1: everything but the three files that wire the server to
    # OpenVoxDB, so the site's code runs on a server wired as the fresh
    # install left it, as on the original build. Pass 2: the configuration
    # whole, over what the site's code has written.
    $wiring = ['/etc/puppetlabs/puppet/puppet.conf', '/etc/puppetlabs/puppet/puppetdb.conf', '/etc/puppetlabs/puppet/routes.yaml']
    $passes = ('config' in $wanted) ? {
      true    => [
        run_plan('ovadm::subplans::restore_pass', $pass + { 'scope' => $wanted, 'exclude' => $wiring }),
        run_plan('ovadm::subplans::restore_pass', $pass + { 'scope' => ['config'], 'install_termini' => $termini_missing }),
      ],
      default => [run_plan('ovadm::subplans::restore_pass', $pass + { 'scope' => $wanted })],
    }
    $status = run_plan('ovadm::status', { 'server_host' => $target })
    out::message("Restore of ${archive} on ${name} complete. Files added since the backup were left alone.")
    return({
      'verify'  => $verify,
      'restore' => $passes.map |$p| { $p['restore'] },
      'agent'   => $passes.map |$p| { $p['agent'] },
      'status'  => $status,
    })
  }

  $one = run_plan('ovadm::subplans::restore_pass', $pass + { 'scope' => $scope, 'install_termini' => $termini_missing })
  $status = run_plan('ovadm::status', { 'server_host' => $target })

  out::message("Restore of ${archive} on ${name} complete. Files added since the backup were left alone.")

  return({ 'verify' => $verify, 'restore' => $one['restore'], 'agent' => $one['agent'], 'status' => $status })
}
