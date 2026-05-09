# @summary Validate that a target is ready to run OpenVox Server
#
# @param server_host
#   The target node to validate
#
plan ovadm::subplans::precheck(
  TargetSpec $server_host,
) {
  $results = run_task('ovadm::precheck', $server_host)

  $results.each |$result| {
    $data = $result.value

    if $data['status'] == 'fail' {
      $failures = $data['checks'].filter |$c| { $c['status'] == 'fail' }
      $messages = $failures.map |$c| { "${c['check']}: ${c['detail']}" }
      fail_plan("Precheck failed on ${result.target.name}: ${messages.join(', ')}")
    }

    $warns = $data['checks'].filter |$c| { $c['status'] == 'warn' }
    $warns.each |$c| {
      out::message("WARNING ${result.target.name} — ${c['check']}: ${c['detail']}")
    }
  }

  return $results
}
