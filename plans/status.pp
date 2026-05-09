# @summary Check the status of an OpenVox Server deployment
#
# @param server_host
#   The target node running OpenVox Server
#
plan ovadm::status(
  TargetSpec $server_host,
) {
  # Precheck — validates OS, Java, port, NTP
  $precheck = run_task('ovadm::precheck', $server_host)

  # Service status
  $services = run_task('ovadm::service_status', $server_host)

  # Build and print a report for each target
  $precheck.each |$result| {
    $target = $result.target.name
    $checks  = $result.value['checks']
    $svc_val = $services.find |$r| { $r.target.name == $target }.value

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
  }

  return({'precheck' => $precheck, 'services' => $services})
}
