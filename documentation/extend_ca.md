# Extending the CA certificate

Every certificate in an OpenVox deployment leads back to the CA certificate on
the server, and that certificate has an end date. When it passes, every agent
run fails at once. Recovering does not take a new CA: `ovadm::extend_ca`
re-signs the CA certificate with the same key and a later end date, so every
certificate the CA ever issued stays valid and no agent is enrolled again.

Two things to know before you start:

- Extend early. An agent fetches a new CA certificate by itself, but only
  over a connection it can verify with the copy it already has. Once that
  copy has expired, the new one has to be carried to each host.
- Nothing about trust changes. The plan gives the certificates a new end date
  and touches nothing else: subject, serial, key and extensions stay as they
  are. It cannot be used to replace a CA, and it refuses a CA whose key is
  kept somewhere else.

## When the CA expires

`ovadm::status` reports it, and warns when less than a year is left:

```text
  ✓ CA certificate CN=Puppet CA: ovox-server.example.com (intermediate): expires on 2041-11-07T17:17:43Z, in 5474 days
  ✓ CA certificate CN=Puppet Root CA: 50644b87b65e23 (root): expires on 2041-11-07T17:17:41Z, in 5474 days
  ✓ certificate of ovox-server.example.com: expires on 2041-11-07T17:17:44Z, in 5474 days
```

How long a CA runs depends on how it was made:

| CA | Made by | Runs for | Expires with it |
| -- | ------- | -------- | --------------- |
| A root and an intermediate (two certificates in `ca_crt.pem`) | `puppetserver ca setup`, which `ovadm::install` has run since ovadm 0.2.0 | 15 years | The root's CRL, which is written once at setup |
| One self-signed certificate | puppetserver itself, on the first start of a server that never ran `ca setup`: ovadm before 0.2.0, and most servers that began as Puppet Server | `ca_ttl`, five years by default | The server's own certificate, signed in the same moment with the same lifetime |

The second kind is the one to watch. Its CA and its server certificate expire
within seconds of each other, so extending the CA alone does not bring such a
server back; the plan replaces the server's certificate as well when it has
expired.

## Extending with ovadm

```bash
bolt plan run ovadm::extend_ca \
  server_host=ovox-server.example.com \
  compiler_hosts=ovox-compiler01.example.com,ovox-compiler02.example.com
```

The plan, in order:

1. Reads the CA on the server and stops if it cannot be extended there.
2. Disables the Puppet agent on the server and the compilers, the way
   [`ovadm::upgrade`](upgrade.md#the-agent-during-the-upgrade) does, so a
   scheduled run cannot start a server the plan has stopped.
3. Takes a backup with `ovadm::backup` and prints the archive's path.
4. Stops puppetserver on the server, re-signs the CA certificates and the
   CA's CRLs, replaces the server's own copy of the bundle, and starts
   puppetserver again. The server is down for as long as a restart takes:
   about a minute on a small VM with OpenVoxDB beside it.
5. Gives each compiler the new bundle and restarts its puppetserver, one
   compiler at a time.
6. Pushes the bundle to the hosts in `agent_hosts`, if you named any.
7. Enables the agents again and reports what each host holds now.

```text
ovox-server.example.com: CN=Puppet CA: ovox-server.example.com (intermediate) expires on 2027-03-02T09:14:07Z, in 110 days
ovox-server.example.com: CN=Puppet Root CA: 50644b87b65e23 (root) expires on 2027-03-02T09:14:05Z, in 110 days
Backup of ovox-server.example.com before the change: /var/backups/openvox/openvox-backup-ovox-server.example.com-20261111T172826Z.tar.gz
ovox-server.example.com: CN=Puppet CA: ovox-server.example.com extended from 2027-03-02T09:14:07Z to 2041-11-07T17:28:31Z
ovox-server.example.com: CN=Puppet Root CA: 50644b87b65e23 extended from 2027-03-02T09:14:05Z to 2041-11-07T17:28:31Z
ovox-server.example.com: CRL of CN=Puppet CA: ovox-server.example.com in /etc/puppetlabs/puppetserver/ca/ca_crl.pem re-signed, now runs until 2041-11-07T17:28:31Z
ovox-server.example.com: CRL of CN=Puppet Root CA: 50644b87b65e23 in /etc/puppetlabs/puppetserver/ca/ca_crl.pem re-signed, now runs until 2041-11-07T17:28:31Z
ovox-compiler01.example.com: bundle installed, puppetserver restarted
ovox-compiler02.example.com: bundle installed, puppetserver restarted
Agents whose copy of the CA is still valid fetch the new bundle themselves within a day (ca_refresh_interval).
CA on ovox-server.example.com extended.
```

| Parameter | Does | Default |
| --------- | ---- | ------- |
| `compiler_hosts` | Compilers to give the bundle and a restart | none |
| `agent_hosts` | Other hosts to push the bundle to | none |
| `ttl` | How long from now the CA should run: a number and `s`, `m`, `h`, `d` or `y` (365 days, as in `ca_ttl`), at most `50y` | `15y` |
| `regenerate_server_cert` | Replace the server's own certificate: `true` always, `false` never | only when it has expired |
| `skip_backup` | Do not take the backup | `false` |
| `backup_destination` | Directory on the server for the backup | `/var/backups/openvox` |
| `dry_run` | Report what would change and stop | `false` |
| `distribute_only` | Extend nothing; push the bundle the CA has now | `false` |

### Look first

```bash
bolt plan run ovadm::extend_ca server_host=ovox-server.example.com dry_run=true
```

prints each certificate and CRL with the end date it has and the one it would
get, and whether the server's certificate would be replaced. Nothing is
written and no service is touched.

### Who gets the new bundle, and how

| Host | Gets it | Needs |
| ---- | ------- | ----- |
| The server | From the plan | Nothing more |
| A compiler | From the plan, when named in `compiler_hosts`. Its agent would fetch the files too, but puppetserver reads them only when it starts | To be named, so that it is restarted |
| An agent whose copy is still valid | By itself, on the first run after its copy is a day old (`ca_refresh_interval`). Until then its old copy works: the keys are the same | Nothing |
| An agent whose copy has expired | Not by itself: it cannot verify the server to ask | To be named in `agent_hosts`, or the [hand step](#agents-the-plan-cannot-reach) |
| OpenVoxDB on the server | From the plan: its copy in `/etc/puppetlabs/puppetdb/ssl/` is replaced and OpenVoxDB restarted | Nothing more |
| OpenVoxDB on another host, or anything else that keeps its own copy of the CA | Nothing refreshes such a copy. It works until the old end date, then stops | To be named in `agent_hosts`, and its service restarted |

A host in `agent_hosts` is checked before it is touched: the bundle is
installed only where it is the CA that signed the host's own certificate. A
failure on one host does not stop the others; the plan finishes them and then
fails, naming the ones it could not do.

### Hosts left out

```bash
bolt plan run ovadm::extend_ca \
  server_host=ovox-server.example.com \
  agent_hosts=db01.example.com,web07.example.com \
  distribute_only=true
```

extends nothing. It takes the bundle the CA has now and gives it to the
server, the compilers and the hosts named, for the compiler you forgot, the
host that was down, and the agents of an expired CA you get to later. A host
that already has the bundle is left alone, though each compiler named is
restarted.

## An expired CA

The server keeps running, and every agent run ends like this:

```text
Error: The certificate 'CN=Puppet CA: ovox-server.example.com' has expired, verify time is synchronized
Error: Could not obtain certificates: The certificate 'CN=Puppet CA: ovox-server.example.com' has expired, verify time is synchronized
```

`ovadm::status` says which certificates have expired:

```text
  ✗ CA certificate CN=Puppet CA: ovox-server.example.com (root): expired on 2026-11-11T17:41:58Z; extend it with ovadm::extend_ca
  ✗ certificate of ovox-server.example.com: expired on 2026-11-11T17:42:02Z
```

Bolt reaches the hosts over SSH, not through the CA, so the same plan works:

```bash
bolt plan run ovadm::extend_ca \
  server_host=ovox-server.example.com \
  compiler_hosts=ovox-compiler01.example.com \
  agent_hosts=agents
```

Here `agents` is a group in your inventory. With a CA that has expired, every
agent needs the bundle pushed, so name as many as Bolt can reach, in this run
or in later ones with `distribute_only=true`.

### The server's own certificate

When the server's certificate has expired too, the plan replaces it, with the
procedure the OpenVox documentation gives for
[an expired server certificate](https://docs.openvoxproject.org/openvox-server/latest/certificate_renewal.html):
the old certificate and its key are moved aside and `puppetserver ca generate
--ca-client` issues a new one from the CA.

- The new certificate has the subject alternative names of the old one. The
  command does not carry them over by itself, and a server certificate
  without `puppet` or your load balancer's name is one that agents reject.
- The extensions set in `csr_attributes.yaml`, such as `pp_role`, are on the
  new certificate as they were on the old. The plan warns if one is missing.
- The old certificate, its keys and the CA's signed copy are kept in
  `/etc/puppetlabs/puppet/ssl.server-cert.<timestamp>.bak/`.
- Where OpenVoxDB on the server uses copies of the server's certificate and
  key, they are replaced with the new ones.

Agents do not notice: the new certificate comes from the CA they trust.

### Certificates of agents and compilers

Extending the CA does not renew anything it signed. On a five-year-old
deployment, the agents enrolled in its first days have certificates that
expired with the CA, and the plan lists every host it touched whose own
certificate has expired or will within 30 days. Such a host is enrolled
again: remove its certificate on the server with `puppetserver ca clean
--certname <name>`, run `puppet ssl clean` on the host, and enroll it as a
new one, by hand or with [`ovadm::add_agent`](add_agent.md). To stop
certificates from running out in the first place, turn on
[auto-renewal](install.md#certificate-auto-renewal).

### Agents the plan cannot reach

On a host Bolt cannot reach, remove the agent's expired copy and let it
download the bundle again:

```bash
rm "$(puppet config print localcacert)"
puppet agent -t
```

The agent then takes the bundle the server sends, as it did on the day it
enrolled, with nothing to check it against. To have it checked, give the
agent the bundle's checksum, taken on the server:

```bash
# on the server
sha256sum /etc/puppetlabs/puppetserver/ca/ca_crt.pem

# on the agent
puppet agent -t --ca_fingerprint <that checksum>
```

The agent refuses a bundle with any other checksum.

## What changes on disk

On the server, in `/etc/puppetlabs/puppetserver/ca/`:

- `ca_crt.pem` holds the same certificates with a later end date.
- `ca_crl.pem` and `infra_crl.pem` hold the same CRLs with the same revoked
  certificates, the next CRL number, and an end date no earlier than the
  certificate that issued them. The server rewrites the signing CA's CRL on
  every revocation and renews it by itself; the root's CRL is rewritten only
  here.
- Each file replaced has a copy beside it, `<name>.<timestamp>.bak`.

The keys, `inventory.txt`, `serial` and the signed certificates are not
touched.

On every host that gets the bundle: `ssl/certs/ca.pem` (`localcacert`),
`ssl/crl.pem` (`hostcrl`) where the host keeps one, and OpenVoxDB's `ca.pem`
where there is one. Owner and mode stay as they were.

## Going back

The extended bundle and the one before it vouch for the same keys, so a host
that holds either one trusts the same certificates, and there is rarely a
reason to go back. If you need to, stop puppetserver, put the `.bak` copies
in the CA directory back under their names, copy `ca_crt.pem` over the
server's `localcacert`, and start puppetserver; or restore the archive from
step 3 with [`ovadm::restore`](backup_restore.md#restoring-a-lost-ca) and
`scope='["ca"]'`. Hosts that already fetched the extended bundle keep
working with it.

## What is not covered

- **A CA issued by another CA.** The plan refuses a bundle with a certificate
  whose key is not on the server. Whoever holds that key extends it, and
  `puppetserver ca import` brings the result in.
- **A new CA key.** That is a new CA, and every certificate issued again.
- **Moving from one self-signed certificate to a root and an intermediate.**
  The same: a new CA.
- **Finding the agents.** ovadm keeps no list of the fleet; `agent_hosts`
  takes the targets and groups of your inventory.
- **Doing it without Bolt.** The OpenVox documentation walks through
  [extending a single-certificate CA by hand](https://docs.openvoxproject.org/openvox-server/latest/certificate_renewal.html#extend-an-expired-ca-certificate).
  The tasks this plan runs can also be used one at a time: `ovadm::ca_expiry`,
  `ovadm::ca_extend`, `ovadm::ca_bundle_install` and
  `ovadm::server_cert_regen`, each described in the
  [reference](../REFERENCE.md).
