# @summary Install and wire codavox onto an OpenVox Server deployment
#
# Installs codavox on the server and compilers, serves a seeded environment from
# the server, converges each compiler's agent, then points OpenVox Server at
# codavox — in that order, because a compiler wired before its agent has
# converged has no code to serve and its catalogs fail to compile.
#
# It reuses the Puppet CA and the compiler certificates (with pp_role
# openvox_compiler) that add_compiler already provisioned; codavox's mutual TLS
# needs nothing new.
#
# @param server_host
#   The OpenVox Server; runs the codavox publisher.
#
# @param compiler_hosts
#   The compiler node(s); run the agent and are wired into OpenVox Server.
#
# @param codavox_version
#   codavox release to install from the official packages.
#
# @param package_url
#   Direct URL to a codavox package, overriding codavox_version. Use for a local
#   snapshot when testing unreleased code.
#
# @param staging
#   r10k's basedir, which the publisher serves.
#
# @param deploy_server
#   Also run the deploy API and webhook daemon on the server.
#
plan ovadm::codavox(
  TargetSpec          $server_host,
  TargetSpec          $compiler_hosts,
  String[1]           $codavox_version = '0.2.1',
  Optional[String[1]] $package_url     = undef,
  String[1]           $staging         = '/etc/puppetlabs/code-staging',
  Boolean             $deploy_server   = false,
) {
  $server_fqdn = run_command('hostname -f', $server_host).first.value['stdout'].strip

  # Install the package everywhere codavox runs.
  run_task('ovadm::install_codavox', [$server_host, $compiler_hosts], {
    'version'     => $codavox_version,
    'package_url' => $package_url,
  })

  # Config per role; both reuse the node's Puppet SSL material.
  run_task('ovadm::configure_codavox', $server_host, {
    'role'    => 'publisher',
    'staging' => $staging,
  })
  run_task('ovadm::configure_codavox', $compiler_hosts, {
    'role'      => 'agent',
    'publisher' => "https://${server_fqdn}:8150",
  })

  # Server: seed an environment, then serve it. The publisher seals staging at
  # startup, so seeding first means it comes up already serving the environment.
  run_task('ovadm::seed_environment', $server_host, { 'staging' => $staging })
  run_command('systemctl enable --now codavox-publish', $server_host)
  if $deploy_server {
    run_command('systemctl enable --now codavox-deploy-server', $server_host)
  }

  # Compilers: converge before wiring. The agent populates the environment link;
  # only once code-id answers is it safe to point OpenVox Server at codavox.
  run_command('systemctl enable --now codavox-agent', $compiler_hosts)
  run_task('ovadm::wait_for_environment', $compiler_hosts, { 'environment' => 'production' })
  run_task('ovadm::wire_codavox', $compiler_hosts)
  run_command('systemctl restart puppetserver', $compiler_hosts)

  out::message('codavox wired: publisher serving on the server, agents converged, compilers on static catalogs.')
}
