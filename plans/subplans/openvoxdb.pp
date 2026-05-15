# @summary Install and configure OpenVoxDB, then connect it to OpenVox Server
#
# When puppetdb_host is the same node as server_host (co-located), only the
# packages and service setup are needed — the server cert already exists.
# When puppetdb_host is a separate node, this subplan handles repo setup,
# agent install, and certificate signing before starting the service.
#
# @param server_host
#   The OpenVox Server (CA) node
#
# @param puppetdb_host
#   The node to run OpenVoxDB on
#
# @param db_password
#   PostgreSQL password for the OpenVoxDB database user
#
# @param co_located
#   True when puppetdb_host is the same node as server_host; skips cert setup
#
# @param db_name
#   PostgreSQL database name (default: puppetdb)
#
# @param db_user
#   PostgreSQL username (default: puppetdb)
#
# @param db_host
#   PostgreSQL server hostname (default: localhost, relative to puppetdb_host)
#
# @param db_port
#   PostgreSQL server port (default: 5432)
#
# @param store_reports
#   Enable report storage in OpenVoxDB (default: true)
#
plan ovadm::subplans::openvoxdb(
  TargetSpec          $server_host,
  TargetSpec          $puppetdb_host,
  String[1]           $db_password,
  Boolean             $co_located    = true,
  String[1]           $db_name       = 'puppetdb',
  String[1]           $db_user       = 'puppetdb',
  String[1]           $db_host       = 'localhost',
  Integer             $db_port       = 5432,
  Boolean             $store_reports = true,
  Optional[String[1]] $ovox_version  = undef,
  Optional[String[1]] $apt_base_url  = undef,
  Optional[String[1]] $yum_base_url  = undef,
) {
  $install_params = $ovox_version ? {
    undef   => {},
    default => { 'version' => $ovox_version },
  }

  if $co_located {
    # Server cert already exists; install both packages on the single node
    run_task('ovadm::install_openvoxdb', $puppetdb_host, $install_params)
  } else {
    $server_fqdn = run_command('hostname -f', $server_host).first.value['stdout'].strip

    $ovox_major = $ovox_version ? {
      undef   => 8,
      default => Integer($ovox_version.split('\.')[0]),
    }

    $repo_params_1 = { 'ovox_major' => $ovox_major }
    $repo_params_2 = $apt_base_url ? {
      undef   => $repo_params_1,
      default => $repo_params_1 + { 'apt_base_url' => $apt_base_url },
    }
    $repo_params = $yum_base_url ? {
      undef   => $repo_params_2,
      default => $repo_params_2 + { 'yum_base_url' => $yum_base_url },
    }

    # Bootstrap the PuppetDB node with a puppet agent so it can get a cert
    run_task('ovadm::configure_repo', $puppetdb_host, $repo_params)
    run_task('ovadm::install_agent', $puppetdb_host, $install_params)
    run_task('ovadm::configure_puppet_conf', $puppetdb_host, {
      'server'    => $server_fqdn,
      'ca_server' => $server_fqdn,
    })

    # Get a signed cert before starting OpenVoxDB
    $certname = run_command('hostname -f', $puppetdb_host).first.value['stdout'].strip
    run_task('ovadm::set_csr_attributes', $puppetdb_host, { 'pp_role' => 'openvox_puppetdb' })
    run_task('ovadm::agent_runonce', $puppetdb_host, { 'waitforcert' => 0 })
    run_task('ovadm::sign_csr', $server_host, { 'certname' => $certname })
    run_task('ovadm::agent_runonce', $puppetdb_host)

    # Install openvoxdb on the PuppetDB node, termini on the server
    run_task('ovadm::install_openvoxdb', $puppetdb_host, $install_params)
    run_task('ovadm::install_openvoxdb', $server_host,
      $install_params + { 'termini_only' => true })
  }

  run_task('ovadm::configure_openvoxdb', $puppetdb_host, {
    'db_host'     => $db_host,
    'db_port'     => $db_port,
    'db_name'     => $db_name,
    'db_user'     => $db_user,
    'db_password' => $db_password,
  })

  run_command('systemctl enable --now puppetdb', $puppetdb_host)
  run_task('ovadm::wait_until_openvoxdb_ready', $puppetdb_host)

  $puppetdb_fqdn = run_command('hostname -f', $puppetdb_host).first.value['stdout'].strip

  run_task('ovadm::configure_server_for_openvoxdb', $server_host, {
    'puppetdb_host' => $puppetdb_fqdn,
    'store_reports' => $store_reports,
  })

  run_command('systemctl restart puppetserver', $server_host)
  run_task('ovadm::wait_until_service_ready', $server_host)
}
