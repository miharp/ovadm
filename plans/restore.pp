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
# @param server_host
#   The OpenVox Server node
#
# @param archive
#   Path of the archive on the server
#
# @param scope
#   What to put back: `ca`, `config`, `code`, `extra` (the paths given as
#   `extra_paths` at backup time). Default: everything the archive holds.
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
#   brings back what it owns.
#
# @return
#   `verify`, `restore` and `agent` results from the tasks, and `status`
#   from `ovadm::status`; with `dry_run`, `verify` and `restore` only.
#
plan ovadm::restore(
  TargetSpec                                         $server_host,
  String[1]                                          $archive,
  Optional[Array[Enum['ca', 'config', 'code', 'extra'], 1]] $scope = undef,
  Boolean                                            $force        = false,
  Boolean                                            $dry_run      = false,
  Optional[String[1]]                                $age_identity = undef,
  Boolean                                            $deploy_code  = true,
  Boolean                                            $agent_run    = true,
) {
  $target = get_targets($server_host)[0]
  $name   = $target.name

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

  $restore_params = {
    'archive' => $archive,
    'force'   => $force,
    'dry_run' => $dry_run,
  } + $age + ($scope ? {
    undef   => {},
    default => { 'scope' => $scope.join(',') },
  })
  $restore = run_task('ovadm::backup_restore', $target, $restore_params).first.value

  $restore['warnings'].each |$w| { out::message("WARNING ${name}: ${w}") }
  $verb = $dry_run ? { true => 'would change', default => 'changed' }
  out::message("${name}: scope ${restore['scope'].join(', ')}: ${restore['changed'].length} file(s) ${verb}, ${restore['missing'].length} missing on the host, ${restore['unchanged']} unchanged")
  if $dry_run {
    ($restore['changed'] + $restore['missing']).each |$f| { out::message("  ${f}") }
    return({ 'verify' => $verify, 'restore' => $restore })
  }
  unless $restore['services_stopped'].empty {
    out::message("${name}: ${restore['services_stopped'].join(' and ')} stopped for the copy and started again")
  }

  # Gems the manifest lists that this host lacks: the ones an operator
  # installed by hand. Reinstalled from rubygems; a failure is reported, not
  # fatal, since the files are already back.
  $restore['missing_gems']['puppetserver'].each |$gem| {
    $m = $gem.match(/^(.*)-([^-]+)$/)
    $r = run_command("puppetserver gem install --no-document ${m[1]} -v ${m[2]}", $target, '_catch_errors' => true)
    if $r.ok { out::message("${name}: installed puppetserver gem ${gem}") } else { out::message("WARNING ${name}: puppetserver gem ${gem} could not be installed: ${r.first.error.message}") }
  }
  $restore['missing_gems']['agent'].each |$gem| {
    $m = $gem.match(/^(.*)-([^-]+)$/)
    $r = run_command("/opt/puppetlabs/puppet/bin/gem install --no-document ${m[1]} -v ${m[2]}", $target, '_catch_errors' => true)
    if $r.ok { out::message("${name}: installed agent gem ${gem}") } else { out::message("WARNING ${name}: agent gem ${gem} could not be installed: ${r.first.error.message}") }
  }

  # Up, whatever state the host was in: a restore means the server should run.
  run_command('systemctl start puppetserver', $target)
  run_task('ovadm::wait_until_service_ready', $target)

  if $deploy_code and 'code' in $restore['scope'] {
    $r10k = run_command('test -x /opt/puppetlabs/puppet/bin/r10k', $target, '_catch_errors' => true)
    if $r10k.ok {
      $deploy = run_command('/opt/puppetlabs/puppet/bin/r10k deploy environment --modules', $target, '_catch_errors' => true)
      if $deploy.ok {
        out::message("${name}: code redeployed with r10k")
      } else {
        $r10k_errors = $deploy.first.value['stderr'].split("\n").filter |$l| { $l =~ /ERROR/ }.join("\n  ")
        out::message("WARNING ${name}: r10k deploy exited ${deploy.first.value['exit_code']}; the environments are as r10k left them:\n  ${r10k_errors}")
      }
    } else {
      out::message("${name}: r10k is not installed; the code directory is as the archive holds it")
    }
  }

  $agent = $agent_run ? {
    true    => run_task('ovadm::agent_runonce', $target, { 'waitforcert' => 0 }).first.value,
    default => undef,
  }
  if $agent and $agent['status'] == 'failed' {
    fail_plan("${name}: the agent run after the restore failed (exit ${agent['exit_code']}); the files are back, the services are up, see the agent's output", 'ovadm/restore')
  }

  $status = run_plan('ovadm::status', { 'server_host' => $target })

  out::message("Restore of ${archive} on ${name} complete. Files added since the backup were left alone.")

  return({ 'verify' => $verify, 'restore' => $restore, 'agent' => $agent, 'status' => $status })
}
