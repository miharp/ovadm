# @summary Revoke certificates, on the CA and on every compiler
#
# Revokes the certificates named on the server that is the CA, then installs
# the CA's CRL on the compilers, so the hosts are refused everywhere when the
# plan ends. Nothing is restarted.
#
# `puppetserver ca revoke` alone reaches the server only: a compiler keeps
# its own copy of the CRL and goes on compiling catalogs for a revoked host
# until that copy is replaced. See `documentation/crl.md`.
#
# The server's own certificate is refused. A compiler's may be revoked, to
# retire it: the plan says so, since agents refuse a revoked compiler as soon
# as they have the new CRL, within a day.
#
# @param server_host
#   The OpenVox Server node that is the CA
#
# @param certnames
#   The certnames to revoke: one, several separated by commas, or an array
#
# @param compiler_hosts
#   Compiler pool nodes (Large topology). Each gets the CRL after the
#   revocation. The plan warns when the server knows of a compiler that is
#   not among them.
#
# @param clean
#   Also delete each certificate, or pending request, from the CA
#   (`puppetserver ca clean`), so the certname can be enrolled again. Without
#   it the revoked certificate stays in the CA's `signed` directory, and a
#   new request under the same name is refused.
#
# @return
#   `certnames`, per certname what the CA answered (`revoked`,
#   `already_revoked`, `not_signed`, `not_found` or `error`) and whether it
#   was cleaned; `crls`, `synced`, `failed`, `host_cert_revoked` and
#   `compilers_not_named` as `ovadm::sync_crl` returns them.
#
plan ovadm::revoke(
  TargetSpec           $server_host,
  Variant[
    Pattern[/\A[A-Za-z0-9_][A-Za-z0-9._-]*(,[A-Za-z0-9_][A-Za-z0-9._-]*)*\z/],
    Array[Pattern[/\A[A-Za-z0-9_][A-Za-z0-9._-]*\z/], 1]
  ]                    $certnames,
  Optional[TargetSpec] $compiler_hosts = undef,
  Boolean              $clean          = false,
) {
  $servers = get_targets($server_host)
  unless $servers.length == 1 {
    fail_plan("server_host must name one host, the CA; it names ${servers.length}", 'ovadm/revoke')
  }
  $server = $servers[0]
  $name   = $server.name
  $compilers = $compiler_hosts ? {
    undef   => [],
    default => get_targets($compiler_hosts).filter |$t| { $t.name != $name },
  }
  $given = $certnames ? {
    String  => $certnames.split(','),
    default => $certnames,
  }
  $names = $given.unique

  # Before anything is revoked: is this the CA, and is its own certificate
  # among the names.
  $topo = run_task('ovadm::topology', $server).first.value
  unless $topo['ca'] {
    fail_plan("${name} has no CA directory, so it is not the CA. Name the server that is.", 'ovadm/revoke')
  }
  if $topo['certname'] in $names {
    fail_plan("${topo['certname']} is the certificate of the CA server itself. Revoking it takes the deployment down; nothing was changed.", 'ovadm/revoke')
  }
  $retired = $names.filter |$n| { $n in $topo['compilers'] }
  unless $retired.empty {
    out::message("${retired.join(', ')}: a compiler. Agents refuse a revoked compiler once they have the new CRL, within a day; take it out of the pool first.")
  }

  $revocation = run_task('ovadm::cert_revoke', $server, {
    'certnames'     => $names,
    'clean'         => $clean,
    '_catch_errors' => true,
  }).first
  $answers = $revocation.value['results'] ? {
    undef   => {},
    default => $revocation.value['results'],
  }
  if $answers.empty {
    # The task refused, or the CA could not be reached: nothing was revoked.
    fail_plan($revocation.error.msg, 'ovadm/revoke')
  }
  $answers.each |$certname, $answer| {
    $what = $answer['status'] ? {
      'revoked'         => 'revoked',
      'already_revoked' => 'was already revoked',
      'not_signed'      => 'has a pending request and no certificate, so there was nothing to revoke',
      'not_found'       => 'ERROR: the CA has no certificate of that name',
      default           => "ERROR: ${answer['detail']}",
    }
    $also = $answer['cleaned'] ? {
      true    => ', and deleted from the CA',
      default => '',
    }
    out::message("${certname}: ${what}${also}")
  }

  # The compilers, whether or not this run changed the CRL: one made by hand
  # earlier is carried along.
  $sync = run_plan('ovadm::subplans::crl_sync', { 'server_host' => $server, 'hosts' => $compilers, 'kind' => 'ovadm/revoke' })

  $result = { 'certnames' => $answers } + $sync
  $unanswered = $answers.filter |$certname, $answer| { $answer['status'] in ['not_found', 'error'] }.keys

  unless $unanswered.empty and $sync['failed'].empty {
    $problems = [
      $unanswered.empty ? {
        true    => undef,
        default => "the CA did not revoke ${unanswered.join(', ')}",
      },
      $sync['failed'].empty ? {
        true    => undef,
        default => "${sync['failed'].keys.join(', ')} did not get the CRL and may still serve the revoked hosts; run ovadm::sync_crl for them",
      },
    ].filter |$p| { $p != undef }
    fail_plan("Not finished: ${problems.join('; ')}.", 'ovadm/revoke', $result)
  }

  $in_force = $answers.filter |$certname, $answer| { $answer['status'] in ['revoked', 'already_revoked'] }
  if $in_force.empty {
    out::message('No certificate was revoked.')
  } else {
    $where = $compilers.empty ? {
      true    => "on ${name}",
      default => "on ${name} and ${sync['synced'].length} compiler(s)",
    }
    out::message("Revocation in force ${where}.")
  }
  return($result)
}
