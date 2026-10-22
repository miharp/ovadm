# @summary Check the status of an OpenVox Server deployment
#
# @param server_host
#   The target node running OpenVox Server
#
# @return
#   A hash of `ovadm_version` (the version of ovadm doing the reporting) plus
#   the raw `precheck`, `services`, `versions` and `topology` results. The
#   topology is what the server knows about the deployment from its own
#   files: its certname and whether it is the CA, the compilers (signed
#   certificates carrying `pp_role=openvox_compiler`), where it sends
#   OpenVoxDB traffic, and the OpenVoxDB database and PostgreSQL on the host.
#
plan ovadm::status(
  TargetSpec $server_host,
) {
  # ovadm's own version, so a deployment can say which ovadm built it. Read
  # from metadata.json rather than hardcoded: the release workflow already
  # refuses a tag that disagrees with metadata.json, so the tag is the source.
  $metadata = file::read("${module_directory('ovadm')}/metadata.json")
  $version_match = $metadata.match(/"version"\s*:\s*"([^"]+)"/)
  $ovadm_version = $version_match ? {
    undef   => 'unknown',
    default => $version_match[1],
  }

  $precheck = run_task('ovadm::precheck', $server_host)
  $services = run_task('ovadm::service_status', $server_host)
  $versions = run_task('ovadm::get_version', $server_host)
  $topology = run_task('ovadm::topology', $server_host)

  out::message("ovadm ${ovadm_version}")

  $precheck.each |$result| {
    $target  = $result.target.name
    $checks  = $result.value['checks']
    $svc_val = $services.find($target).value
    $ver_val = $versions.find($target).value
    $topo    = $topology.find($target).value

    out::message("=== ${target} ===")

    $checks.each |$c| {
      $icon = $c['status'] ? {
        'pass' => '✓',
        'warn' => '!',
        default => '✗',
      }
      out::message("  ${icon} ${c['check']}: ${c['detail']}")
    }

    $svc_val['services'].each |$svc| {
      $icon = $svc['status'] ? {
        'running' => '✓',
        default   => '✗',
      }
      out::message("  ${icon} service/${svc['service']}: ${svc['status']}")
    }

    $server_label = $ver_val['package'] ? {
      'puppetserver' => 'Puppet Server (not yet upgraded to OpenVox)',
      default        => 'OpenVox Server',
    }
    out::message("  ${server_label}: ${ver_val['version']}")

    # Topology, as the server's own files describe it.
    $ca_label = $topo['ca'] ? {
      true    => 'CA',
      default => 'no CA directory',
    }
    $compilers = $topo['compilers']
    $compiler_label = $compilers.length ? {
      0       => 'no compilers',
      1       => "1 compiler: ${compilers[0]}",
      default => "${compilers.length} compilers: ${compilers.join(', ')}",
    }
    out::message("  Topology: server ${topo['certname']} (${$ca_label}), ${compiler_label}")

    $db = $topo['openvoxdb']
    $urls = $db['server_urls']
    if $urls.empty {
      out::message('  OpenVoxDB: the server sends nothing to OpenVoxDB (no puppetdb.conf)')
    } else {
      out::message("  OpenVoxDB: the server reports to ${urls.join(', ')}")
    }
    if $db['version'] {
      $database = $db['database']
      $db_label = $database ? {
        undef   => 'database connection not readable',
        default => $database['local'] ? {
          true    => "database ${database['name']} on this host (port ${database['port']})",
          default => "database ${database['name']} on ${database['host']}:${database['port']}",
        },
      }
      out::message("  OpenVoxDB ${db['version']} on this host, ${db_label}")
    }
    $pg = $topo['postgresql']
    if $pg['version'] {
      out::message("  PostgreSQL ${pg['version']} on this host")
    }
  }

  return({
    'ovadm_version' => $ovadm_version,
    'precheck'      => $precheck,
    'services'      => $services,
    'versions'      => $versions,
    'topology'      => $topology,
  })
}
