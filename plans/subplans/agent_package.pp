# @summary Install openvox-agent on agent hosts and point them at the server
#
# @api private
#
# Configures the repository, installs `openvox-agent`, writes `puppet.conf`
# and, given a `pp_role`, `csr_attributes.yaml`.
# A target that fails a step is left out of the following ones, so that one
# bad host does not stop the rest of the batch; the plan returns the targets
# that got through and the failures by target name.
#
# @param agent_hosts
#   The agent node(s) to set up
#
# @param server
#   The name the agents ask for catalogs from: the server's FQDN, or a
#   compiler's or a load balancer's
#
# @param ca_server
#   The server's FQDN, the CA the agents get their certificates from
#
# @param ovox_major
#   OpenVox major version whose repository to set up
#
# @param ovox_version
#   Specific openvox-agent version to install; omit for the newest in the
#   repository
#
# @param environment
#   Puppet environment the agents ask for; omit for the server's default
#
# @param pp_role
#   Role to request in the agents' certificates, through `csr_attributes.yaml`
#   written before their first agent run. Omitted, the file is left as it is
#
# @return [Hash] `ok`, the names of the targets that got through every step,
#   and `failed`, a hash of target name to error message
#
plan ovadm::subplans::agent_package(
  TargetSpec          $agent_hosts,
  String[1]           $server,
  String[1]           $ca_server,
  Integer[8]          $ovox_major,
  Optional[String[1]] $ovox_version = undef,
  Optional[String[1]] $apt_base_url = undef,
  Optional[String[1]] $yum_base_url = undef,
  Optional[String[1]] $environment  = undef,
  Optional[String[1]] $pp_role      = undef,
) {
  $targets = get_targets($agent_hosts)

  $repo_params_1 = { 'ovox_major' => $ovox_major }
  $repo_params_2 = $apt_base_url ? {
    undef   => $repo_params_1,
    default => $repo_params_1 + { 'apt_base_url' => $apt_base_url },
  }
  $repo_params = $yum_base_url ? {
    undef   => $repo_params_2,
    default => $repo_params_2 + { 'yum_base_url' => $yum_base_url },
  }
  $repo = run_task('ovadm::configure_repo', $targets, $repo_params + { '_catch_errors' => true })

  $install_params = $ovox_version ? {
    undef   => {},
    default => { 'version' => $ovox_version },
  }
  $install = run_task('ovadm::install_agent', $repo.ok_set.targets, $install_params + { '_catch_errors' => true })

  $conf_params_1 = {
    'server'    => $server,
    'ca_server' => $ca_server,
  }
  $conf_params = $environment ? {
    undef   => $conf_params_1,
    default => $conf_params_1 + { 'environment' => $environment },
  }
  $conf = run_task('ovadm::configure_puppet_conf', $install.ok_set.targets, $conf_params + { '_catch_errors' => true })

  # The first agent run creates the CSR, so the role has to be in place
  # before it. The task merges the role into a site's own
  # csr_attributes.yaml (a challengePassword for policy-based autosigning,
  # say) rather than replacing it; without a role the file is not touched.
  $csr_steps = $pp_role ? {
    undef   => [],
    default => [run_task('ovadm::set_csr_attributes', $conf.ok_set.targets, {
      'pp_role'       => $pp_role,
      '_catch_errors' => true,
    })],
  }

  $steps  = [$repo, $install, $conf] + $csr_steps
  $errors = $steps.map |$step| { $step.error_set.results }.flatten
  $failed = Hash($errors.map |$r| { [$r.target.name, $r.error.message] })

  return({ 'ok' => $steps[-1].ok_set.names, 'failed' => $failed })
}
