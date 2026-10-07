# @summary Add one or more compiler nodes to an existing OpenVox Server deployment
#
# @param server_host
#   The OpenVox Server (acts as CA)
#
# @param compiler_hosts
#   The compiler node(s) to install and enroll
#
# @param ovox_version
#   OpenVox Agent version (e.g. '8.26.2'); determines which major repo to enable
#
# @param ovox_server_version
#   Specific openvox-server version to install on compilers. Omitted, along
#   with ovox_version and package_url, the compilers get the version the
#   server runs, so the pool stays on one version
#
plan ovadm::add_compiler(
  TargetSpec          $server_host,
  TargetSpec          $compiler_hosts,
  Optional[String[1]] $ovox_version        = undef,
  Optional[String[1]] $ovox_server_version = undef,
  Optional[String[1]] $apt_base_url        = undef,
  Optional[String[1]] $yum_base_url        = undef,
  Optional[String[1]] $package_url         = undef,
) {
  # With no version given, the compilers get the server's, so a pool added to
  # after an upgrade does not fall back to the newest OpenVox 8.
  if $ovox_version or $ovox_server_version or $package_url {
    $compiler_server_version = $ovox_server_version
  } else {
    $installed = run_task('ovadm::get_version', $server_host).first.value
    if $installed['package'] != 'openvox-server' {
      $found = $installed['package'] ? {
        undef   => 'no openvox-server',
        default => "${installed['package']} ${installed['version']}",
      }
      fail_plan(@("MSG"/L))
        ${server_host} has ${found}, so there is no version to give the compilers. \
        Upgrade it to OpenVox with ovadm::upgrade first, or pass ovox_server_version.
        |- MSG
    }
    # get_version reports the package version with its release, such as
    # 9.0.1-1.el10 or 8.16.0-1+ubuntu24.04; install_server takes the part before.
    $compiler_server_version = $installed['version'].match(/\A(?:\d+:)?([^-]+)/)[1]
    out::message("Installing openvox-server ${compiler_server_version} on the compilers, the version ${server_host} runs.")
  }

  # The major version the repository is set up for, as subplans::agent_install
  # works it out, so that precheck checks the Java that major runs.
  $ovox_major = $ovox_version ? {
    undef   => $compiler_server_version ? {
      undef   => 8,
      default => Integer($compiler_server_version.split('\.')[0]),
    },
    default => Integer($ovox_version.split('\.')[0]),
  }

  run_plan('ovadm::subplans::precheck', { 'server_host' => $compiler_hosts, 'ovox_major' => $ovox_major })

  $server_fqdn = run_command('hostname -f', $server_host).first.value['stdout'].strip

  run_plan('ovadm::subplans::agent_install', {
    'compiler_hosts'      => $compiler_hosts,
    'server_fqdn'         => $server_fqdn,
    'ovox_version'        => $ovox_version,
    'ovox_server_version' => $compiler_server_version,
    'apt_base_url'        => $apt_base_url,
    'yum_base_url'        => $yum_base_url,
    'package_url'         => $package_url,
  })

  run_plan('ovadm::subplans::cert_setup', {
    'compiler_hosts' => $compiler_hosts,
    'server_host'    => $server_host,
  })

  run_task('ovadm::configure_compiler_ssl', $compiler_hosts)

  run_command('systemctl enable --now puppetserver', $compiler_hosts)

  out::message('Compiler(s) added to the pool.')
}
