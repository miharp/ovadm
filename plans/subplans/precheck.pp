# @summary Validate that a target is ready to run OpenVox Server
#
# @api private
#
# @param server_host
#   The target node to validate
#
# @param upgrade
#   Whether the target is about to be upgraded by ovadm::upgrade, which
#   selects a supported Java itself, so an older default Java is only a warning
#
# @param ovox_major
#   The OpenVox major version about to be installed or upgraded to, when
#   known. On 9 and later the server picks its own Java, so the system java is
#   not checked
#
plan ovadm::subplans::precheck(
  TargetSpec           $server_host,
  Boolean              $upgrade    = false,
  Optional[Integer[8]] $ovox_major = undef,
) {
  $params = $ovox_major ? {
    undef   => { 'upgrade' => $upgrade },
    default => { 'upgrade' => $upgrade, 'ovox_major' => $ovox_major },
  }
  $results = run_task('ovadm::precheck', $server_host, $params)

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
