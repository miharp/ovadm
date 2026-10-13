# @summary Submit and sign certificates for compiler hosts
#
# @api private
#
# For each compiler: runs the agent to submit a CSR, signs it on the server,
# then runs the agent again to apply the initial catalog. When that run
# applies no catalog on a compiler, the others are still enrolled, and the
# plan then fails, naming each such compiler, so the calling plan configures
# and starts none of them.
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
#   the run fails instead when the environment is missing, and so does the
#   plan
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

  $failures = $targets.map |$compiler| {
    $certname = run_command('hostname -f', $compiler).first.value['stdout'].strip

    # Embed pp_role in the CSR so the signed cert carries the compiler role
    run_task('ovadm::set_csr_attributes', $compiler, { 'pp_role' => 'openvox_compiler' })

    # Submit CSR (waitforcert=0 means submit and exit immediately). Where the
    # CA does not autosign this run ends without a certificate and fails,
    # which is expected, so its status is not checked.
    run_task('ovadm::agent_runonce', $compiler, $run_params + { 'waitforcert' => 0 })

    run_task('ovadm::sign_csr', $server_host, { 'certname' => $certname })

    # First catalog. agent_runonce exits 0 whatever the agent did and reports
    # the agent's exit status instead, so a run that applied no catalog (the
    # environment is missing on the server, the catalog failed to compile or
    # to apply) has to be read off the status, or the plan goes on to start
    # puppetserver on a compiler the site's code never configured.
    $run = run_task('ovadm::agent_runonce', $compiler, $run_params).first.value
    $run['status'] ? {
      Enum['no_changes', 'changes_applied'] => undef,
      'failed'                              => "${compiler.name}: puppet agent exited ${run['exit_code']} on its first catalog run",
      default                               => "${compiler.name}: agent_runonce reported ${run['status']} on its first catalog run",
    }
  }.filter |$failure| { $failure =~ NotUndef }

  unless $failures.empty {
    $hint = $environment ? {
      undef   => '',
      default => " Check that the environment ${environment} is deployed on the server.",
    }
    fail_plan(@("MSG"/L))
      The first catalog run applied no catalog on ${failures.length} of ${targets.length} compiler(s):
      ${failures.join("\n")}
      Run `puppet agent -t` on each to see why.${hint} No compiler has had SSL \
      configured or puppetserver started; their certificates are signed, and once \
      the cause is fixed, ovadm::add_compiler for the same compilers finishes the job.
      | MSG
  }
}
