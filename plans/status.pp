# @summary Check the status of an OpenVox Server deployment
#
# @param server_host
#   The target node running OpenVox Server
#
# @return
#   A hash of `ovadm_version` (the version of ovadm doing the reporting) plus
#   the raw `precheck`, `services`, `versions`, `topology` and `ca_expiry`
#   results. The topology is what the server knows about the deployment from
#   its own files: its certname and whether it is the CA, the compilers
#   (signed certificates carrying `pp_role=openvox_compiler`), where it sends
#   OpenVoxDB traffic, and the OpenVoxDB database and PostgreSQL on the host.
#   `ca_expiry` is when the CA certificates, the CRLs and the host's own
#   certificate expire. The report warns when a CA certificate has less than
#   a year left, or a CRL or the host's certificate less than 30 days, and
#   names `ovadm::extend_ca` for the first two.
#
plan ovadm::status(
  TargetSpec $server_host,
) {
  # ovadm's own version, so a deployment can say which ovadm built it.
  $ovadm_version = ovadm::version()

  $precheck = run_task('ovadm::precheck', $server_host)
  $services = run_task('ovadm::service_status', $server_host)
  $versions = run_task('ovadm::get_version', $server_host)
  $topology = run_task('ovadm::topology', $server_host)
  $expiry   = run_task('ovadm::ca_expiry', $server_host)

  # A CA certificate is extended well before it expires, because an agent
  # can only fetch the new one while its copy is still valid.
  $ca_warn_days   = 365
  $cert_warn_days = 30

  out::message("ovadm ${ovadm_version}")

  $precheck.each |$result| {
    $target  = $result.target.name
    $checks  = $result.value['checks']
    $svc_val = $services.find($target).value
    $ver_val = $versions.find($target).value
    $topo    = $topology.find($target).value
    $exp     = $expiry.find($target).value

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

    # Certificates: the CA's on the CA, the host's copy elsewhere, and the
    # host's own.
    $ca = $exp['ca']
    $ca_certs = $ca ? {
      undef   => $exp['local_ca'] ? {
        undef   => [],
        default => $exp['local_ca']['certificates'].map |$c| { $c + { 'label' => "copy of CA certificate ${c['subject']}" } },
      },
      default => $ca['certificates'].map |$c| { $c + { 'label' => "CA certificate ${c['subject']} (${c['role']})" } },
    }
    $ca_certs.each |$c| {
      if $c['expired'] {
        out::message("  ✗ ${c['label']}: expired on ${c['not_after']}; extend it with ovadm::extend_ca")
      } elsif $c['days_left'] < $ca_warn_days {
        out::message("  ! ${c['label']}: expires on ${c['not_after']}, in ${c['days_left']} days; extend it with ovadm::extend_ca")
      } else {
        out::message("  ✓ ${c['label']}: expires on ${c['not_after']}, in ${c['days_left']} days")
      }
    }
    if $ca {
      $ca['crls'].filter |$c| { $c['days_left'] < $cert_warn_days }.each |$c| {
        $state = $c['expired'] ? {
          true    => "expired on ${c['next_update']}",
          default => "expires on ${c['next_update']}, in ${c['days_left']} days",
        }
        out::message("  ! CRL of ${c['issuer']} in ${c['path']}: ${state}; ovadm::extend_ca re-signs it")
      }
      if $exp['local_ca'] and $exp['local_ca']['matches_ca'] == false {
        out::message("  ! ${exp['local_ca']['path']}, the copy of the CA this server trusts, differs from the CA directory; ovadm::extend_ca with distribute_only=true replaces it")
      }
    }
    if $exp['openvoxdb_ca'] and $exp['openvoxdb_ca']['matches_local'] == false {
      out::message("  ! ${exp['openvoxdb_ca']['path']}, OpenVoxDB's copy of the CA, differs from the host's; ovadm::extend_ca with distribute_only=true replaces it")
    }
    $own = $exp['host_cert']
    if $own and $own['not_after'] {
      if $own['expired'] {
        out::message("  ✗ certificate of ${exp['certname']}: expired on ${own['not_after']}")
      } elsif $own['days_left'] < $cert_warn_days {
        out::message("  ! certificate of ${exp['certname']}: expires on ${own['not_after']}, in ${own['days_left']} days")
      } else {
        out::message("  ✓ certificate of ${exp['certname']}: expires on ${own['not_after']}, in ${own['days_left']} days")
      }
    }
  }

  return({
    'ovadm_version' => $ovadm_version,
    'precheck'      => $precheck,
    'services'      => $services,
    'versions'      => $versions,
    'topology'      => $topology,
    'ca_expiry'     => $expiry,
  })
}
