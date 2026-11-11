# @summary Extend the CA certificate of an OpenVox deployment
#
# Re-signs the CA certificate (a single self-signed one, or a root and its
# intermediate) and the CA's CRLs with a later expiry, on the server that is
# the CA, and puts the new bundle where it is needed. The keys do not change,
# so every certificate the CA has issued stays valid and no agent is
# re-enrolled. Works before the CA expires and after.
#
# The server is stopped for the change and started again; each compiler
# named is given the bundle and restarted in turn. Agents whose copy of the
# CA is still valid fetch the new one themselves within a day
# (`ca_refresh_interval`). An agent whose copy has expired cannot, and
# neither can anything else that keeps a copy of its own: name those hosts
# in `agent_hosts`.
#
# The Puppet agent on the server and the compilers is disabled for the
# duration and enabled again at the end, as in `ovadm::upgrade`, so a
# scheduled run cannot start the server in the middle.
#
# @param server_host
#   The OpenVox Server node that is the CA
#
# @param compiler_hosts
#   Compiler pool nodes (Large topology). Each gets the new bundle and a
#   puppetserver restart, one at a time.
#
# @param agent_hosts
#   Hosts to push the new bundle to: agents whose copy of the CA has
#   expired, and hosts that keep a copy nothing refreshes, such as an
#   OpenVoxDB on its own host. A failure on one does not stop the others.
#
# @param ttl
#   How long from now the CA certificates should run, as a number and a unit
#   (`s`, `m`, `h`, `d`, `y`), at most `50y`. A year is 365 days, as in
#   Puppet's `ca_ttl`.
#
# @param regenerate_server_cert
#   Replace the server's own certificate with a new one from the CA. By
#   default this happens only when that certificate has expired, which is
#   the case on a CA puppetserver generated for itself: there the server's
#   certificate expires in the same second as the CA. `true` replaces it
#   regardless, `false` never does.
#
# @param skip_backup
#   Do not take a backup of the server first. The backup is `ovadm::backup`
#   with its defaults, under `backup_destination`.
#
# @param backup_destination
#   Directory on the server for the backup archive
#
# @param distribute_only
#   Do not extend anything: take the bundle the CA has now and put it on the
#   server, the compilers and the hosts in `agent_hosts`. For the hosts left
#   out of an earlier run, and for a compiler or agent host that failed in
#   one. Safe to repeat: a host that already has the bundle is not touched,
#   though each compiler named is restarted.
#
# @param dry_run
#   Report what would change and stop. Nothing is written and no service is
#   touched.
#
# @return
#   `ca`, the `ca_extend` result (which certificates and CRLs changed, and
#   the copies kept of the files replaced), or undef with `distribute_only`;
#   `server_cert`, the
#   `server_cert_regen` result, or undef; `backup`, the archive path, or
#   undef; `installed`, per target name what `ca_bundle_install` changed;
#   `failed`, per target name why a compiler or agent host was not
#   finished; `expiry`, per target name the expiry of its copy of the CA
#   and of its own certificate afterwards; `agents_held`, the targets whose
#   agent the plan disabled and enabled again. With `dry_run`: `ca` and
#   `regenerate_server_cert` only.
#
plan ovadm::extend_ca(
  TargetSpec                $server_host,
  Optional[TargetSpec]      $compiler_hosts         = undef,
  Optional[TargetSpec]      $agent_hosts            = undef,
  Pattern[/\A\d+[smhdy]\z/] $ttl                    = '15y',
  Optional[Boolean]         $regenerate_server_cert = undef,
  Boolean                   $skip_backup            = false,
  String[1]                 $backup_destination     = '/var/backups/openvox',
  Boolean                   $distribute_only        = false,
  Boolean                   $dry_run                = false,
) {
  if $distribute_only and $regenerate_server_cert == true {
    fail_plan('regenerate_server_cert=true needs the server stopped, which distribute_only does not do. Run the plan without distribute_only.', 'ovadm/extend-ca')
  }

  $servers = get_targets($server_host)
  unless $servers.length == 1 {
    fail_plan("server_host must name one host, the CA; it names ${servers.length}", 'ovadm/extend-ca')
  }
  $server = $servers[0]
  $name   = $server.name
  $compilers = $compiler_hosts ? {
    undef   => [],
    default => get_targets($compiler_hosts),
  }
  $agents = $agent_hosts ? {
    undef   => [],
    default => get_targets($agent_hosts),
  }

  # What is there now, and whether it can be extended at all.
  $before = run_task('ovadm::ca_expiry', $server, { 'include_bundle' => $distribute_only }).first.value
  $ca = $before['ca']
  if $ca == undef {
    fail_plan("${name} has no CA directory, so it is not the CA. Name the server that is.", 'ovadm/extend-ca')
  }
  $ca['certificates'].each |$c| {
    $when = $c['expired'] ? {
      true    => "expired on ${c['not_after']}",
      default => "expires on ${c['not_after']}, in ${c['days_left']} days",
    }
    out::message("${name}: ${c['subject']} (${c['role']}) ${when}")
  }
  if $distribute_only and $ca['expired'] {
    fail_plan("The CA on ${name} has expired, so there is no bundle worth distributing. Run the plan without distribute_only to extend it.", 'ovadm/extend-ca')
  }
  if $distribute_only and $ca['bundle'] == undef {
    fail_plan("The CA bundle on ${name} cannot be read: ${ca['problems'].join('; ')}", 'ovadm/extend-ca')
  }
  unless $distribute_only or $ca['extendable'] {
    fail_plan("The CA on ${name} cannot be extended: ${ca['problems'].join('; ')}", 'ovadm/extend-ca')
  }
  $was_expired = $ca['expired']

  $host_cert = $before['host_cert']
  $server_cert_expired = ($host_cert != undef and $host_cert['expired'] == true)
  $regenerate = $distribute_only ? {
    true    => false,
    default => $regenerate_server_cert ? {
      undef   => $server_cert_expired,
      default => $regenerate_server_cert,
    },
  }
  if $server_cert_expired {
    out::message("${name}: the server's own certificate expired on ${host_cert['not_after']}")
    unless $regenerate {
      out::message("WARNING ${name}: the server keeps that certificate, and no agent will accept it. Run the plan without distribute_only and without regenerate_server_cert=false to replace it.")
    }
  }

  if $dry_run and $distribute_only {
    $to = ([$server] + $compilers + $agents).map |$t| { $t.name }.join(', ')
    out::message("Dry run: would install the bundle ${name} has now on ${to}, and restart puppetserver on the compilers. Nothing was changed.")
    return({ 'ca' => undef, 'regenerate_server_cert' => false })
  }

  if $dry_run {
    $would = run_task('ovadm::ca_extend', $server, { 'ttl' => $ttl, '_noop' => true }).first.value
    $would['certificates'].each |$c| {
      out::message("${name}: would extend ${c['subject']} from ${c['old_not_after']} to ${c['new_not_after']}")
    }
    $would['crls'].each |$c| {
      out::message("${name}: would re-sign the CRL of ${c['issuer']} in ${c['path']} to run until ${c['new_next_update']}")
    }
    if $regenerate {
      out::message("${name}: would replace the server's own certificate")
    }
    out::message('Dry run: nothing was changed.')
    return({ 'ca' => $would, 'regenerate_server_cert' => $regenerate })
  }

  # Keep the agents out of the way on the servers: a run in the middle would
  # start a puppetserver this plan has stopped. As in ovadm::upgrade.
  $held_targets = [$server] + $compilers
  $lock_prefix = 'ovadm extend_ca'
  $disabled = run_task('ovadm::agent_disable', $held_targets, {
    'message'       => "${lock_prefix} in progress",
    'reclaim'       => $lock_prefix,
    '_catch_errors' => true,
  })
  $held = $disabled.ok_set.filter_set |$r| { $r.value['disabled_here'] }.targets
  $disabled.ok_set.filter_set |$r| { $r.value['status'] == 'already_disabled' }.each |$r| {
    out::message("${r.target.name}: the agent was already disabled (${r.value['message']}); it stays disabled afterwards.")
  }
  unless $disabled.ok {
    unless $held.empty {
      run_task('ovadm::agent_enable', $held, { 'only_message' => $lock_prefix, '_catch_errors' => true })
    }
    $why = $disabled.error_set.map |$r| { "${r.target.name}: ${r.error.msg}" }.join('; ')
    fail_plan("Could not disable the agent, so nothing was changed. ${why}", 'ovadm/extend-ca')
  }

  $outcome = catch_errors() || {
    # The way back: the CA directory and the server's certificates, verified.
    $archive = ($skip_backup or $distribute_only) ? {
      true    => undef,
      default => run_plan('ovadm::backup', {
        'server_host' => $server_host,
        'destination' => $backup_destination,
      })['archives'][$name],
    }
    if $archive {
      out::message("Backup of ${name} before the change: ${archive}")
    }

    $change = if $distribute_only {
      # The bundle as it is. The server's own trusted copy may still be the
      # old one, and puppetserver reads it only when it starts.
      $bundle_params = { 'bundle' => $ca['bundle'] } + ($ca['crl'] ? {
        undef   => {},
        default => { 'crl' => $ca['crl'] },
      })
      $on_server = run_task('ovadm::ca_bundle_install', $server, $bundle_params).first.value
      $openvoxdb_changed = ($on_server['openvoxdb_ca'] != undef and $on_server['openvoxdb_ca']['action'] == 'updated')
      if $openvoxdb_changed {
        run_command('systemctl try-restart puppetdb', $server, '_catch_errors' => true)
        out::message("${name}: OpenVoxDB's copy of the CA was replaced and OpenVoxDB restarted")
      }
      if $on_server['changed'].empty {
        out::message("${name}: already has the bundle")
      } else {
        run_task('ovadm::service_restart', $server)
        run_task('ovadm::wait_until_service_ready', $server, { 'puppetdb' => $openvoxdb_changed })
        out::message("${name}: updated ${on_server['changed'].join(', ')}, puppetserver restarted")
      }
      ({ 'extended' => undef, 'regenerated' => undef, 'bundle_params' => $bundle_params, 'on_server' => $on_server })
    } else {
      # The server holds the CA in memory and rewrites the CRL on a
      # revocation, so it is stopped for the change. Whatever happens in
      # between, it is started again: ca_extend either replaces every file
      # or none.
      run_task('ovadm::service_stop', $server)
      $changed = catch_errors() || {
        $extended = run_task('ovadm::ca_extend', $server, { 'ttl' => $ttl }).first.value
        $extended['certificates'].each |$c| {
          out::message("${name}: ${c['subject']} extended from ${c['old_not_after']} to ${c['new_not_after']}")
        }
        $extended['crls'].each |$c| {
          out::message("${name}: CRL of ${c['issuer']} in ${c['path']} re-signed, now runs until ${c['new_next_update']}")
        }
        $extended['warnings'].each |$w| { out::message("WARNING ${name}: ${w}") }

        $regenerated = $regenerate ? {
          true    => run_task('ovadm::server_cert_regen', $server).first.value,
          default => undef,
        }
        if $regenerated {
          out::message("${name}: the server's certificate was replaced; the new one runs until ${regenerated['new_not_after']}. The old one and its key are in ${regenerated['backup']}")
          unless $regenerated['extensions_lost'].empty {
            out::message("WARNING ${name}: the new certificate lacks extensions the old one had: ${regenerated['extensions_lost']}")
          }
          if $regenerated['alt_names_dropped'] > 0 {
            out::message("WARNING ${name}: ${regenerated['alt_names_dropped']} subject alternative name(s) that are neither DNS names nor IP addresses were not carried over")
          }
        }

        $bundle_params = { 'bundle' => $extended['bundle'] } + ($extended['crl'] ? {
          undef   => {},
          default => { 'crl' => $extended['crl'] },
        })
        # The server's own trusted copy, which puppetserver reads when it
        # starts and does not refresh from the CA directory.
        $on_server = run_task('ovadm::ca_bundle_install', $server, $bundle_params).first.value

        ({ 'extended' => $extended, 'regenerated' => $regenerated, 'bundle_params' => $bundle_params, 'on_server' => $on_server })
      }

      # OpenVoxDB reads its copies when it starts; only one that is running
      # is restarted.
      $openvoxdb_changed = $changed =~ Error ? {
        true    => false,
        default => (
          ($changed['on_server']['openvoxdb_ca'] != undef and $changed['on_server']['openvoxdb_ca']['action'] == 'updated')
          or ($changed['regenerated'] != undef and $changed['regenerated']['openvoxdb'] == 'updated')
        ),
      }
      if $openvoxdb_changed {
        run_command('systemctl try-restart puppetdb', $server, '_catch_errors' => true)
        out::message("${name}: OpenVoxDB's copies were replaced and OpenVoxDB restarted")
      }
      run_task('ovadm::service_start', $server)
      if $changed =~ Error {
        out::message("${name}: the change failed and puppetserver was started again as it was.")
        fail_plan($changed)
      }
      run_task('ovadm::wait_until_service_ready', $server, { 'puppetdb' => $openvoxdb_changed })
      $changed
    }

    # Compilers load the bundle when puppetserver starts, so each one gets a
    # restart whether its agent had already fetched the files or not. One at
    # a time, so the pool keeps serving.
    $compiler_results = $compilers.reduce({}) |$memo, $compiler| {
      $installed = run_task('ovadm::ca_bundle_install', $compiler, $change['bundle_params'] + { '_catch_errors' => true }).first
      $problem = if !$installed.ok {
        $installed.error.msg
      } elsif !($installed.value['status'] in ['installed', 'unchanged']) {
        "it has no certificate from this CA (${installed.value['status']})"
      } else {
        $restarted = run_task('ovadm::service_restart', $compiler, { '_catch_errors' => true }).first
        if !$restarted.ok {
          $restarted.error.msg
        } else {
          $ready = run_task('ovadm::wait_until_service_ready', $compiler, { '_catch_errors' => true }).first
          if $ready.ok { undef } else { $ready.error.msg }
        }
      }
      if $problem {
        out::message("ERROR ${compiler.name}: ${problem}")
      } else {
        out::message("${compiler.name}: bundle installed, puppetserver restarted")
      }
      $memo + { $compiler.name => { 'problem' => $problem, 'value' => $installed.ok ? { true => $installed.value, default => undef } } }
    }

    # Everything else that was named, all at once, each on its own.
    $agent_results = $agents.empty ? {
      true    => {},
      default => run_task('ovadm::ca_bundle_install', $agents, $change['bundle_params'] + { '_catch_errors' => true }).reduce({}) |$memo, $r| {
        $problem = if !$r.ok {
          $r.error.msg
        } elsif !($r.value['status'] in ['installed', 'unchanged']) {
          "it has no certificate from this CA (${r.value['status']})"
        } else {
          undef
        }
        if $problem {
          out::message("ERROR ${r.target.name}: ${problem}")
        } else {
          $what = $r.value['changed'].empty ? {
            true    => 'already had the new bundle',
            default => "updated ${r.value['changed'].join(', ')}",
          }
          out::message("${r.target.name}: ${what}")
          if $r.value['openvoxdb_ca'] != undef and $r.value['openvoxdb_ca']['action'] == 'updated' {
            out::message("${r.target.name}: OpenVoxDB's copy of the CA was replaced. Restart OpenVoxDB there to load it.")
          }
        }
        $memo + { $r.target.name => { 'problem' => $problem, 'value' => $r.ok ? { true => $r.value, default => undef } } }
      },
    }

    $others = $compiler_results + $agent_results
    ({
      'archive'     => $archive,
      'extended'    => $change['extended'],
      'regenerated' => $change['regenerated'],
      'installed'   => { $name => $change['on_server']['changed'] } + $others.filter |$n, $r| { $r['problem'] == undef }.map |$n, $r| { [$n, $r['value']['changed']] }.convert_to(Hash),
      'failed'      => $others.filter |$n, $r| { $r['problem'] != undef }.map |$n, $r| { [$n, $r['problem']] }.convert_to(Hash),
    })
  }

  # Enable the agents this run disabled, on the failure path as well.
  unless $held.empty {
    $enabled = run_task('ovadm::agent_enable', $held, { 'only_message' => $lock_prefix, '_catch_errors' => true })
    $enabled.ok_set.filter_set |$r| { $r.value['status'] == 'left_disabled' }.each |$r| {
      out::message("${r.target.name}: the agent was disabled again meanwhile (${r.value['message']}); it stays disabled.")
    }
    unless $enabled.ok {
      out::message("Could not enable the agent again on ${enabled.error_set.names.join(', ')}. Run 'puppet agent --enable' there.")
    }
  }

  if $outcome =~ Error {
    out::message('Extending the CA failed. The agents this plan disabled are enabled again, unless a line above names a host where that failed.')
    fail_plan($outcome)
  }

  # What every host touched holds now, and which of them have a certificate
  # of their own that the extension does not help.
  $after = run_task('ovadm::ca_expiry', [$server] + $compilers + $agents, { '_catch_errors' => true })
  $expiry = $after.ok_set.reduce({}) |$memo, $r| {
    $local = $r.value['local_ca']
    $own   = $r.value['host_cert']
    $memo + { $r.target.name => {
        'ca_not_after'        => $local ? { undef => undef, default => $local['not_after'] },
        'host_cert_not_after' => $own ? { undef => undef, default => $own['not_after'] },
        'host_cert_days_left' => $own ? { undef => undef, default => $own['days_left'] },
    } }
  }
  $expiry.each |$host, $e| {
    if $e['host_cert_days_left'] != undef and $e['host_cert_days_left'] < 30 {
      $state = $e['host_cert_days_left'] < 0 ? {
        true    => 'expired',
        default => "expires in ${e['host_cert_days_left']} days",
      }
      out::message("WARNING ${host}: its own certificate ${state} (${e['host_cert_not_after']}). Extending the CA does not renew it; see documentation/extend_ca.md.")
    }
  }

  if $was_expired {
    out::message('The CA had expired, so no agent can fetch the new bundle by itself. Every host not named in agent_hosts needs it pushed: run this plan again with distribute_only=true and those hosts in agent_hosts.')
  } else {
    out::message('Agents whose copy of the CA is still valid fetch the new bundle themselves within a day (ca_refresh_interval).')
  }

  $result = {
    'ca'          => $outcome['extended'] ? {
      undef   => undef,
      default => $outcome['extended'] - ['bundle', 'crl'],
    },
    'server_cert' => $outcome['regenerated'],
    'backup'      => $outcome['archive'],
    'installed'   => $outcome['installed'],
    'failed'      => $outcome['failed'],
    'expiry'      => $expiry,
    'agents_held' => $held.map |$t| { $t.name },
  }

  unless $outcome['failed'].empty {
    fail_plan(
      "The CA on ${name} is extended and the server is running with it, but ${outcome['failed'].keys.join(', ')} did not get the new bundle. Run the plan again with distribute_only=true for those hosts.",
      'ovadm/extend-ca',
      $result,
    )
  }

  $done = $distribute_only ? {
    true    => "CA bundle of ${name} distributed.",
    default => "CA on ${name} extended.",
  }
  out::message($done)

  return($result)
}
