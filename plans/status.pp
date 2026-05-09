# @summary Check the status of an OpenVox Server deployment
#
# @param server_host
#   The target node running OpenVox Server
#
plan ovadm::status(
  TargetSpec $server_host,
) {
  $precheck = run_task('ovadm::precheck', $server_host)
  $services = run_task('ovadm::service_status', $server_host)
  $versions = run_task('ovadm::get_version', $server_host)

  $precheck.each |$result| {
    $target  = $result.target.name
    $checks  = $result.value['checks']
    $svc_val = $services.find |$r| { $r.target.name == $target }.value
    $ver_val = $versions.find |$r| { $r.target.name == $target }.value

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

    out::message("  Version: ${ver_val['version']}")
  }

  return({'precheck' => $precheck, 'services' => $services, 'versions' => $versions})
}
