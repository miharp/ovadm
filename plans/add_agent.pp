# @summary Add one or more agent nodes to an existing OpenVox Server deployment
#
# Installs `openvox-agent` on stock hosts from the workstation, points them at
# the server (or a compiler or load balancer), signs their certificates on the
# server and runs each agent once, so every host applies its first catalog
# inside the plan. The agent service is left as the package leaves it: ovadm
# does not schedule runs.
#
# A host that fails a step is left out of the following ones and reported at
# the end, with the hosts that got through; the plan then fails, so a batch
# with one bad host still enrolls the others.
#
# @param server_host
#   The OpenVox Server (acts as CA)
#
# @param agent_hosts
#   The agent node(s) to install and enroll
#
# @param agent_server
#   The name the agents ask for catalogs from, written as `server` in their
#   `puppet.conf`. Defaults to the server's FQDN; on a Large topology, give a
#   compiler's FQDN or the load balancer's name in front of the pool. The CA
#   is always the server
#
# @param ovox_version
#   OpenVox Agent version to install (e.g. '8.30.0'); determines which major
#   repo to enable. Omitted, the agents get the newest agent of the major the
#   server runs
#
# @param apt_base_url
#   Base URL of an apt mirror to use instead of https://apt.voxpupuli.org
#
# @param yum_base_url
#   Base URL of a yum/dnf mirror to use instead of https://yum.voxpupuli.org
#
# @param environment
#   Puppet environment the agents ask for from their first run on
#   (`environment` in the `[agent]` section of `puppet.conf`, and
#   `--environment` on the runs inside the plan); omit for the server's
#   default, `production`. It must exist on the server already: a run against
#   an environment the server does not have fails
#
# @param pp_role
#   Role to put in the agents' certificates, as the `pp_role` extension
#   (`$trusted['extensions']['pp_role']`), for sites that classify on it. The
#   plan writes it to `csr_attributes.yaml` before the first agent run,
#   replacing a file already there; omitted, the file is left alone. One role
#   for every host in the run. It takes effect when the certificate is
#   signed, so a host that already has one keeps the role it was signed with.
#   `openvox_server` and `openvox_compiler`, ovadm's roles for the server and
#   compilers, are refused
#
# @return [Hash] `ok`, the names of the agents enrolled, and `servers`, the
#   server each one's `puppet.conf` names after its first catalog, which is
#   `agent_server` unless the site's code changed it (undef where it could not
#   be read)
#
plan ovadm::add_agent(
  TargetSpec          $server_host,
  TargetSpec          $agent_hosts,
  Optional[String[1]] $agent_server = undef,
  Optional[String[1]] $ovox_version = undef,
  Optional[String[1]] $apt_base_url = undef,
  Optional[String[1]] $yum_base_url = undef,
  Optional[String[1]] $environment  = undef,
  Optional[Pattern[/\A[A-Za-z0-9][A-Za-z0-9_.:-]*\z/]] $pp_role = undef,
) {
  # Sites classify compilers on openvox_compiler (documentation/add_compiler.md
  # says to), so an agent given it would be turned into one by its first run.
  if $pp_role in ['openvox_server', 'openvox_compiler'] {
    fail_plan(@("MSG"/L))
      pp_role ${pp_role} is the role ovadm gives the server or its compilers. \
      Give the agents a role of their own.
      |- MSG
  }

  # With no version given, the agents follow the server's major, so an estate
  # on OpenVox 9 does not get OpenVox 8 agents.
  if $ovox_version {
    $ovox_major = Integer($ovox_version.split('\.')[0])
  } else {
    $installed = run_task('ovadm::get_version', $server_host).first.value
    if $installed['package'] != 'openvox-server' {
      $found = $installed['package'] ? {
        undef   => 'no openvox-server',
        default => "${installed['package']} ${installed['version']}",
      }
      fail_plan(@("MSG"/L))
        ${server_host} has ${found}, so there is no OpenVox major to follow for the agents. \
        Upgrade it to OpenVox with ovadm::upgrade first, or pass ovox_version.
        |- MSG
    }
    $ovox_major = Integer($installed['version'].split('\.')[0])
    out::message("Installing the newest openvox-agent ${ovox_major} on the agents, the major ${server_host} runs.")
  }

  run_plan('ovadm::subplans::precheck', { 'server_host' => $agent_hosts, 'role' => 'agent' })

  $server_fqdn = run_command('hostname -f', $server_host).first.value['stdout'].strip
  $catalog_server = $agent_server ? {
    undef   => $server_fqdn,
    default => $agent_server,
  }

  $packaged = run_plan('ovadm::subplans::agent_package', {
    'agent_hosts'  => $agent_hosts,
    'server'       => $catalog_server,
    'ca_server'    => $server_fqdn,
    'ovox_major'   => $ovox_major,
    'ovox_version' => $ovox_version,
    'apt_base_url' => $apt_base_url,
    'yum_base_url' => $yum_base_url,
    'environment'  => $environment,
    'pp_role'      => $pp_role,
  })

  $enrolled = run_plan('ovadm::subplans::agent_enroll', {
    'agent_hosts' => $packaged['ok'],
    'server_host' => $server_host,
    'environment' => $environment,
  })

  $ok     = $enrolled['ok']
  $failed = $packaged['failed'] + $enrolled['failed']

  # The first catalog inside the plan is the site's, and an agent profile
  # that manages `server` in puppet.conf repoints the host there and then.
  # Say where each host was left, not where the plan pointed it.
  $readback = $ok.empty ? {
    true    => [],
    default => run_command('/opt/puppetlabs/bin/puppet config print server --section agent', $ok, '_catch_errors' => true).results,
  }
  $servers = Hash($readback.map |$r| {
    [$r.target.name, $r.ok ? { true => $r.value['stdout'].strip, default => undef }]
  })

  $readback.each |$r| {
    $now = $servers[$r.target.name]
    if $now == $catalog_server {
      out::message("${r.target.name}: enrolled, getting catalogs from ${catalog_server}")
    } elsif $now =~ Undef {
      out::message("${r.target.name}: enrolled; could not read its server setting: ${r.error.message}")
    } else {
      out::message(@("MSG"/L))
        WARNING ${r.target.name}: enrolled, but its first catalog changed server in puppet.conf \
        from ${catalog_server} to ${now}, so it gets catalogs from ${now}. The site's code \
        manages that setting; set it there.
        |- MSG
    }
  }

  unless $failed.empty {
    $lines = $failed.map |$name, $message| { "${name}: ${message}" }
    fail_plan(@("MSG"/L))
      ovadm::add_agent failed on ${$failed.length} of ${get_targets($agent_hosts).length} agent(s):
      ${lines.join("\n")}
      | MSG
  }

  out::message('Agent(s) added.')

  return({ 'ok' => $ok, 'servers' => $servers })
}
