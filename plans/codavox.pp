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
# @param basedir
#   r10k's basedir, which the publisher serves. On a stock install that is the
#   codedir r10k already deploys into; codavox needs no basedir area of its own.
#
# @param deploy_server
#   Also run the deploy API and webhook daemon on the server.
#
plan ovadm::codavox(
  TargetSpec          $server_host,
  TargetSpec          $compiler_hosts,
  String[1]           $codavox_version = '0.6.1',
  Optional[String[1]] $package_url     = undef,
  String[1]           $basedir         = '/etc/puppetlabs/code/environments',
  Boolean             $deploy_server   = false,
) {
  $server_fqdn = run_command('hostname -f', $server_host).first.value['stdout'].strip

  # Install the package everywhere codavox runs. Pass package_url only when it is
  # set: Bolt serializes an undef parameter as the string "null", which would be
  # taken as a literal package path.
  $install_params = $package_url ? {
    undef   => { 'version' => $codavox_version },
    default => { 'package_url' => $package_url },
  }
  $installed = run_task('ovadm::install_codavox', [$server_host, $compiler_hosts], $install_params)

  # Say which codavox landed, and fail if it is not the one asked for. A stale
  # package cache or a wrong URL otherwise shows up much later as a daemon that
  # will not start, because codavox rejects config keys it does not know rather
  # than ignoring them — so an older binary meets a newer config and the error
  # points at the config instead of the version. Skipped when package_url is set,
  # since a snapshot has no version to compare against.
  # goreleaser strips the leading v from tags, so a released binary reports
  # 0.5.0; normalize both sides rather than depending on that staying true.
  $want = $codavox_version.regsubst('^v', '')
  $installed.each |$result| {
    $got = String($result.value['version']).regsubst('^v', '')
    out::message("codavox ${got} on ${result.target.name}")
    if $package_url == undef and $got != $want {
      fail("${result.target.name} has codavox ${got}, but ${want} was requested")
    }
  }

  # Config per role; both reuse the node's Puppet SSL material.
  run_task('ovadm::configure_codavox', $server_host, {
    'role'    => 'publisher',
    'basedir' => $basedir,
  })
  # One URL for both the agents and the later fleet check, so the verification
  # queries exactly the endpoint the agents proved reachable.
  $publisher_url = "https://${server_fqdn}:8150"
  run_task('ovadm::configure_codavox', $compiler_hosts, {
    'role'      => 'agent',
    'publisher' => $publisher_url,
  })

  # Server: seed an environment, then serve it. The publisher seals basedir at
  # startup, so seeding first means it comes up already serving the environment.
  run_task('ovadm::seed_environment', $server_host, { 'basedir' => $basedir })
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

  # Wait for puppetserver to answer again before returning: the restart is what
  # picks up the codavox wiring, and a caller that runs an agent immediately
  # (as the install-test workflow does) would otherwise race a still-starting
  # JVM and fail to fetch a catalog.
  run_task('ovadm::wait_until_service_ready', $compiler_hosts)

  # Confirm from the publisher that every compiler is on the same code_id.
  #
  # wait_for_environment above already asked each compiler individually, so this
  # is not a repeat: it checks the publisher and the compilers *agree*, and that
  # every compiler authenticated and is being served. A node whose certificate
  # the publisher refuses converges on nothing and is simply absent here, which
  # per-node checks on a single compiler cannot reveal.
  $fleet = run_task('ovadm::verify_fleet', $server_host, {
    'expected'  => length(get_targets($compiler_hosts)),
    'publisher' => $publisher_url,
  }).first.value

  out::message(sprintf('codavox wired: %s compiler(s) serving production at %s.',
      $fleet['compilers'], $fleet['code_id']))
}
