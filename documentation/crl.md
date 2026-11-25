# Revoking certificates and the CRL

Revoking a certificate tells the CA to stop trusting it. The CA writes its
serial number to the certificate revocation list (CRL), and every host that
checks certificates against a copy of that list refuses the revoked one from
then on. The catch is the word "copy": the list is only as current as the
last time each host fetched it.

On a deployment with compilers, `puppetserver ca revoke` alone is not enough.
The server refuses the revoked host within a second, and the compilers go on
compiling catalogs for it. `ovadm::revoke` revokes and brings the compilers
up to date in one run.

## How a revocation travels

| Host | The list it checks | When it learns of a revocation |
| --- | --- | --- |
| The server (the CA) | `ssl/crl.pem`, which the server copies from `ca/ca_crl.pem` whenever that changes | Within a second. No restart. |
| A compiler | `ssl/crl.pem`, the copy the Puppet agent on the compiler keeps (`ssl-crl-path` in `webserver.conf`) | When that file is replaced. The compiler reloads it without a restart, but only an agent run on the compiler fetches a new one, and only once the file is a day old (`crl_refresh_interval`). |
| An agent | `ssl/crl.pem` | On the first agent run after its copy is a day old. |

ovadm does not enable the `puppet` service on the hosts it builds; how agents
are scheduled is the site's decision. On a compiler where the agent does not
run, nothing ever replaces the CRL, and a certificate revoked on the CA is
accepted there for as long as it would have been otherwise. Where the agent
does run, the compiler is up to a day behind.

An agent checks the server's certificate against its list, not its own, so
for a revoked agent the lists that matter are the server's and the
compilers'. The agents' own copies matter when a compiler is revoked.

## Revoking a certificate

```bash
bolt plan run ovadm::revoke \
  server_host=ovox-server.example.com \
  compiler_hosts=ovox-compiler01.example.com,ovox-compiler02.example.com \
  certnames=agent07.example.com
```

```text
agent07.example.com: revoked
ovox-compiler01.example.com: CRL updated (/etc/puppetlabs/puppet/ssl/crl.pem)
ovox-compiler02.example.com: CRL updated (/etc/puppetlabs/puppet/ssl/crl.pem)
Revocation in force on ovox-server.example.com and 2 compiler(s).
```

The plan:

1. checks that `server_host` is the CA and that its own certificate is not
   among the names;
2. revokes each certname on the server with `puppetserver ca revoke`;
3. reads the CRL from the CA directory and installs it on every compiler,
   all at once. A compiler that fails does not stop the others.

Nothing is restarted and no agent is run. The revoked host is refused by the
server within a second of step 2 and by each compiler by the time the plan
ends: both reload the list when the file changes.

`certnames` takes one name, several separated by commas, or an array. The
names are certnames as `puppetserver ca list --all` shows them, which are not
always the names in the Bolt inventory.

A standard deployment has no compilers: leave `compiler_hosts` out, and the
plan is the revocation alone.

### Deleting the certificate as well

A revoked certificate stays in the CA's `signed` directory, and the CA
refuses a new request under the same name. To enroll the host again, or to
be rid of a name for good, add `clean=true`:

```bash
bolt plan run ovadm::revoke server_host=ovox-server.example.com \
  compiler_hosts=ovox-compiler01.example.com \
  certnames=agent07.example.com clean=true
```

```text
agent07.example.com: revoked, and deleted from the CA
```

That is `puppetserver ca clean`. It also deletes a request that was never
signed, which the plan reports as "has a pending request and no
certificate".

### What the plan reports and when it fails

| Line | Meaning |
| --- | --- |
| `revoked` | The CA added the certificate to the CRL. |
| `was already revoked` | It was on the CRL before. The compilers still get the CRL, so this is also how to finish a revocation made by hand. |
| `has a pending request and no certificate` | Nothing to revoke. With `clean=true` the request is deleted. |
| `ERROR: the CA has no certificate of that name` | A wrong name, or one already cleaned. |

The plan carries on past a name the CA does not know, so the names it could
revoke are in force everywhere, and then fails so the wrong name is not
missed. It also fails when a compiler did not get the CRL, naming the
compiler and `ovadm::sync_crl`.

### Compilers the plan was not told about

The server knows its compilers: they are the signed certificates that carry
`pp_role=openvox_compiler`, which `ovadm::add_compiler` requests. When one of
them is not in `compiler_hosts`, the plan says so:

```text
WARNING ovox-server.example.com knows of 1 compiler(s) that did not get the CRL: ovox-compiler02.example.com. Each goes on serving a revoked host until its copy is replaced: run ovadm::sync_crl with them in compiler_hosts.
```

### Revoking a compiler

To retire a compiler, take it out of the pool (the load balancer, DNS, the
agents' `server_list`), stop puppetserver on it, then revoke it like any
other host. The plan names it for what it is, and `ovadm::status` lists it
as `(revoked)` until its certificate is cleaned. Agents refuse a revoked
compiler once they have fetched the new CRL, within a day.

The plan refuses the certificate of the CA server itself.

## After a revocation made another way

`puppetserver ca revoke`, `puppetserver ca clean`, the CA's HTTP API and
anything built on them reach the server only. Bring the compilers up to date
afterwards:

```bash
bolt plan run ovadm::sync_crl \
  server_host=ovox-server.example.com \
  compiler_hosts=ovox-compiler01.example.com,ovox-compiler02.example.com
```

```text
ovox-compiler01.example.com: CRL updated (/etc/puppetlabs/puppet/ssl/crl.pem)
ovox-compiler02.example.com: already has the CRL
CRL of ovox-server.example.com installed on 2 host(s).
```

The plan is safe to repeat and safe to schedule. It refuses a CRL that is
not signed by the CA a host already trusts, and it never replaces a newer
list with an older one.

## What `ovadm::status` says

Run it on the server and the compilers together, so it can hold each
compiler's copy against the CA's:

```bash
bolt plan run ovadm::status \
  server_host=ovox-server.example.com,ovox-compiler01.example.com
```

```text
=== ovox-compiler01.example.com ===
  ! copy of the CRL of CN=Puppet CA: ovox-server.example.com: behind the CA's (number 2, the CA has 3), so this host does not refuse the certificates revoked since; ovadm::sync_crl replaces it
  ✓ copy of the CRL of CN=Puppet Root CA: 0e2d3d5c3714ed: the same as the CA's (number 0, 0 revoked)
```

After `ovadm::sync_crl`:

```text
  ✓ copy of the CRL of CN=Puppet CA: ovox-server.example.com: the same as the CA's (number 3, 3 revoked)
```

It also reports a copy with less than 30 days left, a copy that has run out,
a host whose own certificate is revoked, and on the server a compiler whose
certificate is revoked:

```text
  Topology: server ovox-server.example.com (CA), 2 compilers: ovox-compiler01.example.com, ovox-compiler02.example.com (revoked)
```

## When a CRL runs out

A CRL has an end date of its own (`Next Update`). A host that checks
certificates against a list past that date refuses every certificate, not
only the revoked ones.

| CRL | How long it runs | Who renews it |
| --- | --- | --- |
| The signing CA's, in `ca/ca_crl.pem` | 15 years from `puppetserver ca setup`, which `ovadm::install` runs; 5 years from each revocation after that. On a CA puppetserver generated for itself, 5 years from the start. | The server, by itself: when it starts and once a day, it writes a new one if less than 30 days are left. OpenVox Server 8 and Puppet Server 8.4.0 and later; Puppet Server 7 does not. |
| The root's, in the same file | As long as the root certificate | [`ovadm::extend_ca`](extend_ca.md), with the root. The server never rewrites it. |
| A compiler's or an agent's copy | As long as the list it was copied from | An agent run on that host, or `ovadm::sync_crl`. |

So the first revocation shortens the CRL from 15 years to 5. On the server
that goes unnoticed, since it renews the list in time. A compiler's copy is
renewed only by being replaced: one that is never replaced runs out 5 years
after the last revocation it saw, and from that day the compiler refuses
every agent:

```text
Error: Could not retrieve catalog from remote server: Request to https://ovox-compiler01.example.com:8140/puppet/v3/catalog/agent07.example.com?environment=production failed after 0.0 seconds: SSL_read: sslv3 alert certificate unknown
```

`ovadm::status` warns 30 days ahead, and says so when it has happened:

```text
  ✗ copy of the CRL of CN=Puppet CA: ovox-server.example.com: ran out on 2031-11-24T13:13:03Z, so every certificate checked against it is refused; ovadm::sync_crl replaces it
```

`ovadm::sync_crl` puts it right, with no restart.

### An agent whose copy has run out

An agent fetches a new CRL over a connection it checks against the old one.
Once the old one has run out, that connection fails and the agent cannot
help itself:

```text
Error: certificate verify failed [CRL has expired for CN=ovox-server.example.com]
```

This takes an agent that did not run for the last 30 days of its copy's
life, or a clock that is wrong. Name the host in `agent_hosts`:

```bash
bolt plan run ovadm::sync_crl server_host=ovox-server.example.com \
  agent_hosts=agent07.example.com
```

Or, on the host, move the file aside and let the agent fetch the list from
scratch:

```bash
mv /etc/puppetlabs/puppet/ssl/crl.pem /etc/puppetlabs/puppet/ssl/crl.pem.old
puppet agent -t
```

## Keeping compilers current without the plan

If the Puppet agent runs on the compilers on a schedule, each compiler
fetches the CRL itself, a day behind at most. To shorten that, set
`crl_refresh_interval` in the `[agent]` section of the compilers'
`puppet.conf` to less than the run interval, so every run asks the CA
whether the list has changed. The request is small and answered with "not
modified" when nothing has.

That narrows the gap and does not close it. For a revocation that has to
hold now, use `ovadm::revoke`, or `ovadm::sync_crl` after the fact.

## What ovadm leaves alone

- **The infrastructure CRL** (`enable-infra-crl` in `ca.conf`). With it on,
  the CA hands out a short list holding only the revoked infrastructure
  hosts, to keep the download small on very large sites. It hands that list
  to everyone who asks, compilers included, and a compiler needs the full
  list to refuse a revoked agent. If you turn it on, keep the compilers on
  the full list with `ovadm::sync_crl`, which always reads `ca_crl.pem`, and
  do not let the agent on a compiler replace it.
- **Pruning** (`puppetserver ca prune`). It drops duplicate or expired
  entries from the list, needs the server stopped, and matters for lists
  with hundreds of thousands of entries. The server drops expired entries
  itself when it renews the list. With `openvoxserver-ca` older than 3.1.1
  (`/opt/puppetlabs/puppet/bin/gem list openvoxserver-ca`),
  `--remove-expired` and `--remove-entries` could write a list the server
  cannot read
  ([openvox-server#202](https://github.com/OpenVoxProject/openvox-server/issues/202)).
  Take an `ovadm::backup` first on any version, and run `ovadm::sync_crl`
  afterwards.
- **The CRLs of an externally issued CA.** The lists of the certificates
  above the signing CA belong to whoever holds those keys and run out on
  their schedule. New ones go in through the CA's
  `PUT /puppet-ca/v1/certificate_revocation_list` endpoint. `ovadm::status`
  warns when one of them has less than 30 days left.
- **A lost or damaged CRL.** There is no command that rebuilds one with its
  revocations. [`ovadm::restore`](backup_restore.md#restoring-a-lost-ca)
  brings back the list in the backup, and says which certificates were
  revoked since.
- **Taking a revocation back.** A certificate that was revoked by mistake is
  cleaned and the host enrolled again.

## What changes on disk

On the server, `puppetserver ca revoke` rewrites `ca/ca_crl.pem` and the
server copies it to `ssl/crl.pem`; with `clean=true` the certificate leaves
`ca/signed/`. ovadm writes nothing there itself.

On each compiler and each host in `agent_hosts`: `ssl/crl.pem` (`hostcrl`),
replaced by a file written beside it and renamed over it, with the owner and
mode it had. A host that keeps no such file is left without one.

## Tested

On OpenVox Server 8.18.0 with agent 8.34.0: a revoked agent refused by the
server half a second later and served by the compiler until the plan ran; the compiler
reloading the CRL the plan wrote without a restart; a compiler with a CRL
that had run out refusing a valid agent, and serving it again after
`ovadm::sync_crl`; an agent with a CRL that had run out failing as above.
