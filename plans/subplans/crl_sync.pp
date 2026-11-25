# @summary Install the CA's CRLs on hosts that hold a copy of their own
#
# @api private
#
# Reads the CRLs from the CA directory on the server, the full list whatever
# the CA hands out over HTTP, and installs them with `ovadm::crl_install` on
# every host given, all at once. A host that fails does not stop the others.
# Nothing is restarted: a compiler reloads the file when it changes.
#
# Also compares the hosts reached with the compilers the server knows of
# (signed certificates carrying `pp_role=openvox_compiler`), so a compiler
# that was left out is named and not forgotten.
#
# @param server_host
#   The OpenVox Server node that is the CA
#
# @param hosts
#   The hosts to install the CRLs on. May be empty: the comparison with the
#   compilers the server knows of is still made.
#
# @param kind
#   The error kind for a server that is not the CA
#
# @return [Hash] `crls`, the CRLs installed (issuer, CRL number, revoked
#   count, next update); `synced`, per target name the `crl_install` status;
#   `failed`, per target name why its CRLs were not installed;
#   `host_cert_revoked`, the targets whose own certificate is on the CRL;
#   `compilers_not_named`, the certnames of compilers the server knows of
#   that are not revoked and were not among the hosts
#
plan ovadm::subplans::crl_sync(
  TargetSpec $server_host,
  TargetSpec $hosts = [],
  String[1]  $kind  = 'ovadm/sync-crl',
) {
  $server  = get_targets($server_host)[0]
  $name    = $server.name
  $targets = get_targets($hosts)

  $ca = run_task('ovadm::ca_expiry', $server, { 'include_bundle' => true }).first.value['ca']
  if $ca == undef {
    fail_plan("${name} has no CA directory, so it is not the CA. Name the server that is.", $kind)
  }
  if $ca['crl'] == undef {
    fail_plan("${name} has no CRL in its CA directory, so there is nothing to install.", $kind)
  }
  $topo = run_task('ovadm::topology', $server).first.value

  # The CA's own list, not the infrastructure CRL beside it.
  $crls = $ca['crls'].filter |$c| { $c['path'] !~ /infra_crl\.pem\z/ }.map |$c| {
    $c.filter |$k, $v| { $k in ['issuer', 'crl_number', 'revoked', 'next_update', 'days_left', 'expired'] }
  }

  $results = $targets.empty ? {
    true    => {},
    default => run_task('ovadm::crl_install', $targets, { 'crl' => $ca['crl'], '_catch_errors' => true }).reduce({}) |$memo, $r| {
      $problem = if !$r.ok {
        $r.error.msg
      } elsif $r.value['status'] == 'not_installed' {
        'the OpenVox agent is not installed there'
      } elsif $r.value['status'] == 'not_enrolled' {
        "it trusts no CA (${r.value['detail']})"
      } else {
        undef
      }
      if $problem {
        out::message("ERROR ${r.target.name}: ${problem}")
      } else {
        $what = $r.value['status'] ? {
          'updated'    => "CRL updated (${r.value['path']})",
          'unchanged'  => 'already has the CRL',
          'kept_newer' => "holds a newer CRL than ${name} and keeps it",
          default      => 'keeps no CRL, so nothing was installed; its next agent run fetches the list',
        }
        out::message("${r.target.name}: ${what}")
        if $r.value['host_cert_revoked'] == true {
          # A compiler is a server to its agents; any other host is a client.
          $advice = $r.value['certname'] in $topo['compilers'] ? {
            true    => 'Agents refuse it; stop puppetserver there and take it out of the pool.',
            default => "${name} and every compiler that has this CRL refuse it.",
          }
          out::message("WARNING ${r.target.name}: its own certificate (${r.value['certname']}) is revoked. ${advice}")
        }
      }
      $memo + { $r.target.name => { 'problem' => $problem, 'value' => $r.ok ? { true => $r.value, default => undef } } }
    },
  }

  $reached = $results.filter |$n, $r| { $r['problem'] == undef }
  $certnames = $reached.map |$n, $r| { $r['value']['certname'] }
  $not_named = $topo['compilers'].filter |$c| {
    !($c in $certnames) and !($c in $topo['compilers_revoked'])
  }
  unless $not_named.empty {
    out::message("WARNING ${name} knows of ${not_named.length} compiler(s) that did not get the CRL: ${not_named.join(', ')}. Each goes on serving a revoked host until its copy is replaced: run ovadm::sync_crl with them in compiler_hosts.")
  }

  return({
    'crls'                => $crls,
    'synced'              => $reached.map |$n, $r| { [$n, $r['value']['status']] }.convert_to(Hash),
    'failed'              => $results.filter |$n, $r| { $r['problem'] != undef }.map |$n, $r| { [$n, $r['problem']] }.convert_to(Hash),
    'host_cert_revoked'   => $reached.filter |$n, $r| { $r['value']['host_cert_revoked'] == true }.keys,
    'compilers_not_named' => $not_named,
  })
}
