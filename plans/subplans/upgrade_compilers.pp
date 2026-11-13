# @summary Upgrade openvox-server on compiler pool nodes
#
# By default every step runs on all the compilers at once, so the whole pool
# restarts together. With `rolling`, each compiler is taken through all the
# steps and is answering again before the next one is touched; a compiler that
# fails stops the plan, with the ones after it left as they were.
#
# @api private
#
# @param compiler_hosts
#   The compiler node(s) to upgrade
#
# @param ovox_server_version
#   The openvox-server version to upgrade to (e.g. '8.13.0')
#
# @param package_url
#   Direct URL to an openvox-server rpm or deb to install instead of the
#   repository's package
#
# @param ovox_major
#   The OpenVox major version to upgrade to; see ovadm::subplans::upgrade_repo
#
# @param apt_base_url
#   Base URL of an apt mirror to use instead of https://apt.voxpupuli.org
#
# @param yum_base_url
#   Base URL of a yum/dnf mirror to use instead of https://yum.voxpupuli.org
#
# @param rolling
#   Upgrade the compilers one at a time, in the order given, instead of all
#   at once
#
plan ovadm::subplans::upgrade_compilers(
  TargetSpec          $compiler_hosts,
  Optional[String[1]] $ovox_server_version = undef,
  Optional[String[1]] $package_url         = undef,
  Optional[Integer]   $ovox_major          = undef,
  Optional[String[1]] $apt_base_url        = undef,
  Optional[String[1]] $yum_base_url        = undef,
  Boolean             $rolling             = false,
) {
  $install_params = $package_url ? {
    undef   => { 'version' => $ovox_server_version },
    default => { 'package_url' => $package_url },
  }

  # One batch holding every compiler, or one batch per compiler. A batch goes
  # through every step, restart and readiness check included, before the next
  # one starts: the package's own scripts restart the service, so the install
  # cannot be done ahead on the whole pool without taking it down.
  $compilers = get_targets($compiler_hosts)
  $batches = $rolling ? {
    true    => $compilers.map |$compiler| { [$compiler] },
    default => [$compilers],
  }

  $batches.each |$index, $batch| {
    if $rolling {
      out::message("Upgrading compiler ${batch[0].name} (${$index + 1} of ${compilers.length}).")
    }

    $result = catch_errors() || {
      run_plan('ovadm::subplans::upgrade_repo', {
        'targets'      => $batch,
        'ovox_major'   => $ovox_major,
        'apt_base_url' => $apt_base_url,
        'yum_base_url' => $yum_base_url,
      })

      run_task('ovadm::install_server', $batch, $install_params)

      run_task('ovadm::select_java', $batch)

      run_task('ovadm::service_restart', $batch)
      run_task('ovadm::wait_until_service_ready', $batch)
    }

    if $result =~ Error {
      if $rolling {
        $done = $compilers[0, $index].map |$t| { $t.name }
        $left = $compilers[$index + 1, -1].map |$t| { $t.name }
        $done_text = $done.empty ? {
          true    => 'No compiler was upgraded before it.',
          default => "Upgraded before it: ${done.join(', ')}.",
        }
        $left_text = $left.empty ? {
          true    => 'It was the last one.',
          default => "Not touched, and still on the version they had: ${left.join(', ')}.",
        }
        # The error a failed task raises only counts the hosts; what the host
        # said is in the results it carries.
        $details = $result.details ? {
          Hash    => $result.details,
          default => {},
        }
        $why = $details['result_set'] ? {
          ResultSet => $details['result_set'].error_set.map |$r| { $r.error.msg }.join('; '),
          default   => $result.msg,
        }
        out::message("Compiler ${batch[0].name} failed: ${why}")
        out::message("The plan stops here. ${done_text} ${left_text}")
      }
      fail_plan($result)
    }
  }
}
