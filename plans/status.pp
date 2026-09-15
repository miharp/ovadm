# @summary Check the status of an OpenVox Server deployment
#
# @param server_host
#   The target node running OpenVox Server
#
# @return
#   A hash of `ovadm_version` (the version of ovadm doing the reporting) plus
#   the raw `precheck`, `services`, and `versions` results.
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

  out::message("ovadm ${ovadm_version}")

  $precheck.each |$result| {
    $target  = $result.target.name
    $checks  = $result.value['checks']
    $svc_val = $services.find($target).value
    $ver_val = $versions.find($target).value

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

    out::message("  OpenVox Server: ${ver_val['version']}")
  }

  return({
    'ovadm_version' => $ovadm_version,
    'precheck'      => $precheck,
    'services'      => $services,
    'versions'      => $versions,
  })
}
