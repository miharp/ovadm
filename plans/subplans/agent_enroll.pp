# @summary Enrol agent hosts with the CA and apply their first catalog
#
# @api private
#
# Runs the agent on every host to submit its CSR, signs each on the server,
# then runs the agent again so each host applies its first catalog inside the
# plan. Unlike `cert_setup`, which takes compilers one at a time, every agent
# step runs across the whole batch at once, and a host that fails a step is
# left out of the following ones rather than stopping the rest.
#
# @param agent_hosts
#   The agent node(s) to enrol; `openvox-agent` installed and `puppet.conf`
#   written
#
# @param server_host
#   The server that acts as the CA
#
# @param environment
#   Puppet environment both agent runs ask for, as `--environment`; see
#   `cert_setup` for why the runs name it rather than rely on `puppet.conf`
#
# @return [Hash] `ok`, the names of the targets that applied a catalog, and
#   `failed`, a hash of target name to error message
#
plan ovadm::subplans::agent_enroll(
  TargetSpec          $agent_hosts,
  TargetSpec          $server_host,
  Optional[String[1]] $environment = undef,
) {
  $targets = get_targets($agent_hosts)

  $run_params = $environment ? {
    undef   => {},
    default => { 'environment' => $environment },
  }

  # The certname each host will ask the CA for, so the server can sign it.
  $names = run_command('hostname -f', $targets, '_catch_errors' => true)
  $certnames = Hash($names.ok_set.results.map |$r| { [$r.target.name, $r.value['stdout'].strip] })

  # Submit the CSRs (waitforcert=0: submit and exit). Where the CA autosigns,
  # this run already applies the catalog, and sign_csr reports already_signed.
  $submit = run_task('ovadm::agent_runonce', $names.ok_set.targets, $run_params + { 'waitforcert' => 0, '_catch_errors' => true })

  # Sign on the server, one request at a time. A host whose CSR never arrived
  # (it could not reach the CA, say) fails here, with the CA's message.
  $signing = $submit.ok_set.targets.map |$target| {
    $result = run_task('ovadm::sign_csr', $server_host, {
      'certname'      => $certnames[$target.name],
      '_catch_errors' => true,
    }).first
    [$target, $result]
  }
  $signed      = $signing.filter |$pair| { $pair[1].ok }.map |$pair| { $pair[0] }
  $sign_failed = Hash($signing.filter |$pair| { !$pair[1].ok }.map |$pair| { [$pair[0].name, $pair[1].error.message] })

  # First catalog. agent_runonce exits 0 whatever the agent did and reports
  # the agent's exit status instead, so a run that applied nothing (the
  # environment is missing on the server, the catalog failed to compile) is
  # read off the status rather than caught as a task error.
  $apply = run_task('ovadm::agent_runonce', $signed, $run_params + { '_catch_errors' => true })
  $applied    = $apply.ok_set.results.filter |$r| { $r.value['status'] != 'failed' }.map |$r| { $r.target.name }
  $run_failed = Hash($apply.ok_set.results.filter |$r| { $r.value['status'] == 'failed' }.map |$r| {
    [$r.target.name, "puppet agent exited ${r.value['exit_code']} on its first run; its output is above"]
  })

  $errors = $names.error_set.results + $submit.error_set.results + $apply.error_set.results
  $failed = Hash($errors.map |$r| { [$r.target.name, $r.error.message] }) + $sign_failed + $run_failed

  return({ 'ok' => $applied, 'failed' => $failed })
}
