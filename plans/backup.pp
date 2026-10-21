# @summary Back up an OpenVox primary server to one archive
#
# Takes the CA, the server's certificates, its configuration and a record of
# the deployed code from the server into one archive under `destination`,
# with a manifest of the host it came from and the topology the server sees,
# then checks the archive against its own checksums. Copying the archive off
# the host is left to you: it holds the CA's private key.
#
# @param server_host
#   The OpenVox Server node
#
# @param destination
#   Directory on the server for the archive. Created with mode 0700 if it
#   does not exist.
#
# @param backup
#   What to include; everything is on unless switched off. See
#   `Ovadm::Backup_opts`.
#
# @param include_code_tree
#   Take `/etc/puppetlabs/code/` itself, not only the record of what r10k
#   deployed. For sites whose git server shares the primary's blast radius.
#
# @param extra_paths
#   Paths outside `/etc/puppetlabs/` to include, such as the r10k deploy key
#   or the systemd units that run r10k. Each must exist.
#
# @param stop_services
#   Stop puppetserver and puppetdb while the files are copied, and start
#   them again afterwards. Off by default: the CA directory changes only
#   when a certificate is signed or revoked, and the plan reports if that
#   happened during the copy.
#
# @param age_recipient
#   An `age` public key. When set, the archive is encrypted to it and gets
#   the suffix `.age`; `age` must be installed on the server.
#
# @param verify
#   Check the archive's checksums and manifest after writing it.
#
# @return
#   The `backup_create` result: `archive`, `size_bytes`, `files`,
#   `certname`, `created`, `ca_serial_moved`, `warnings`, as `backup`; and
#   `verify`, the `backup_verify` result per target name (empty when
#   `verify` is off).
#
plan ovadm::backup(
  TargetSpec          $server_host,
  String[1]           $destination       = '/var/backups/openvox',
  Ovadm::Backup_opts  $backup            = {},
  Boolean             $include_code_tree = false,
  Array[String[1]]    $extra_paths       = [],
  Boolean             $stop_services     = false,
  Optional[String[1]] $age_recipient     = undef,
  Boolean             $verify            = true,
) {
  $opts = { 'ca' => true, 'config' => true, 'code' => true } + $backup

  unless $opts['ca'] or $opts['config'] or $opts['code'] {
    fail_plan('Nothing to back up: ca, config and code are all off', 'ovadm/backup')
  }

  $create_params = {
    'destination'       => $destination,
    'ca'                => $opts['ca'],
    'config'            => $opts['config'],
    'code'              => $opts['code'],
    'include_code_tree' => $include_code_tree,
    'stop_services'     => $stop_services,
    'ovadm_version'     => ovadm::version(),
  } + ($extra_paths.empty ? {
    true    => {},
    default => { 'extra_paths' => $extra_paths.join(',') },
  }) + ($age_recipient ? {
    undef   => {},
    default => { 'age_recipient' => $age_recipient },
  })

  $created = run_task('ovadm::backup_create', $server_host, $create_params)

  $created.each |$result| {
    $v = $result.value
    $mb = sprintf('%.1f', $v['size_bytes'] / 1048576.0)
    out::message("${result.target.name}: ${v['archive']} (${mb} MB, ${v['files']} files)")
    if $v['ca_serial_moved'] {
      out::message("WARNING ${result.target.name}: a certificate was signed or revoked while the CA directory was copied; take the backup again")
    }
    $v['warnings'].each |$w| {
      out::message("WARNING ${result.target.name}: ${w}")
    }
  }

  # One verify per target, since each has its own archive path. The task
  # reports structural problems in its result rather than failing, so the
  # plan can print them before stopping.
  $verified = $verify ? {
    true    => $created.reduce({}) |$memo, $result| {
      $v = run_task('ovadm::backup_verify', $result.target, { 'archive' => $result.value['archive'] }).first.value
      $v['problems'].each |$p| {
        out::message("ERROR ${result.target.name}: ${p}")
      }
      out::message("${result.target.name}: ${v['checksums']['checked']} checksums checked, ${v['status']}")
      $memo + { $result.target.name => $v }
    },
    default => {},
  }
  $bad = $verified.filter |$name, $v| { $v['status'] != 'ok' }
  unless $bad.empty {
    fail_plan("Backup verification failed on ${bad.keys.join(', ')}", 'ovadm/backup')
  }

  out::message('Copy the archive off the host: it holds the CA private key.')

  return({ 'backup' => $created, 'verify' => $verified })
}
