# @summary Submit and sign certificates for compiler hosts
#
# @api private
#
# For each compiler: runs the agent to submit a CSR, signs it on the server,
# then runs the agent again to apply the initial catalog.
#
# @param compiler_hosts
#   The compiler node(s) whose certificates need to be set up
#
# @param server_host
#   The server that acts as the CA
#
# @param environment
#   Puppet environment both agent runs ask for, as `--environment`. Without
#   it the agent takes the environment the server assigned on its previous
#   run before the one in `puppet.conf`, and the server assigns `production`
#   when the one in `puppet.conf` does not exist yet, so a compiler enrolled
#   before its environment is deployed would stay on `production`. With it,
#   the run fails instead when the environment is missing
#
plan ovadm::subplans::cert_setup(
  TargetSpec          $compiler_hosts,
  TargetSpec          $server_host,
  Optional[String[1]] $environment = undef,
) {
  $targets = get_targets($compiler_hosts)

  $run_params = $environment ? {
    undef   => {},
    default => { 'environment' => $environment },
  }

  $targets.each |$compiler| {
    $certname = run_command('hostname -f', $compiler).first.value['stdout'].strip

    # Embed pp_role in the CSR so the signed cert carries the compiler role
    run_task('ovadm::set_csr_attributes', $compiler, { 'pp_role' => 'openvox_compiler' })

    # Submit CSR (waitforcert=0 means submit and exit immediately)
    run_task('ovadm::agent_runonce', $compiler, $run_params + { 'waitforcert' => 0 })

    run_task('ovadm::sign_csr', $server_host, { 'certname' => $certname })

    run_task('ovadm::agent_runonce', $compiler, $run_params)
  }
}
