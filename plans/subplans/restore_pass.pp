# @summary One pass of a restore: the files of a scope, then the server up
#
# Runs `backup_restore` for the scope, reports what changed, reinstalls the
# gems the manifest lists that the host lacks, installs `openvoxdb-termini`
# when asked, starts puppetserver and waits for it, redeploys the code with
# r10k when `code` is in scope, and runs the agent once. With `dry_run`,
# reports and stops.
#
# @api private
#
# @param target
#   The server
# @param archive
#   Path of the archive on the server
# @param scope
#   The items to put back; undef for everything the archive holds
# @param force
#   As on `ovadm::restore`
# @param dry_run
#   As on `ovadm::restore`
# @param age_identity
#   As on `ovadm::restore`
# @param deploy_code
#   As on `ovadm::restore`
# @param agent_run
#   As on `ovadm::restore`
# @param install_termini
#   Install `openvoxdb-termini` when the host lacks it, before starting the
#   server: the restored `routes.yaml` names the puppetdb terminus
#
# @return
#   `restore`, the `backup_restore` result, and `agent`, the agent run's
#   result or undef
#
plan ovadm::subplans::restore_pass(
  Target                                                    $target,
  String[1]                                                 $archive,
  Optional[Array[Enum['ca', 'config', 'code', 'extra'], 1]] $scope           = undef,
  Boolean                                                   $force           = false,
  Boolean                                                   $dry_run         = false,
  Optional[String[1]]                                       $age_identity    = undef,
  Boolean                                                   $deploy_code     = true,
  Boolean                                                   $agent_run       = true,
  Boolean                                                   $install_termini = false,
) {
  $name = $target.name

  $params = {
    'archive' => $archive,
    'force'   => $force,
    'dry_run' => $dry_run,
  } + ($age_identity ? {
    undef   => {},
    default => { 'age_identity' => $age_identity },
  }) + ($scope ? {
    undef   => {},
    default => { 'scope' => $scope.join(',') },
  })
  $restore = run_task('ovadm::backup_restore', $target, $params).first.value

  $restore['warnings'].each |$w| { out::message("WARNING ${name}: ${w}") }
  $verb = $dry_run ? { true => 'would change', default => 'changed' }
  out::message("${name}: scope ${restore['scope'].join(', ')}: ${restore['changed'].length} file(s) ${verb}, ${restore['missing'].length} missing on the host, ${restore['unchanged']} unchanged")
  if $dry_run {
    ($restore['changed'] + $restore['missing']).each |$f| { out::message("  ${f}") }
    return({ 'restore' => $restore, 'agent' => undef })
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

  # The restored routes.yaml names the puppetdb terminus, so the server
  # cannot start until the termini package is back. The site's code may have
  # installed it already; if not, the repository ovadm::install set up has it.
  if $install_termini {
    $pkg = run_task('ovadm::install_package', $target, { 'name' => 'openvoxdb-termini' }).first.value
    if $pkg['status'] == 'installed' {
      out::message("${name}: installed openvoxdb-termini ${pkg['version']}, which the manifest lists and the host lacked")
    }
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
    out::message("WARNING ${name}: the agent run failed (exit ${agent['exit_code']}); the files are back and the services are up. Run puppet agent -t on the server to see why")
  }
  # The site's code may have restarted puppetserver during that run.
  if $agent {
    run_task('ovadm::wait_until_service_ready', $target)
  }

  return({ 'restore' => $restore, 'agent' => $agent })
}
