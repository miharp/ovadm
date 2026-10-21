# Backing up and restoring OpenVox Server

An OpenVox primary server holds the one thing nothing else in your
infrastructure can replace, the certificate authority, next to configuration
that is cheap to keep and data that the agents rebuild on their own. A good
backup copies the first two every time and the third when you need it. This
page lists what lives on a primary server, why each item matters, and how to
back it up by hand with `tar` and `pg_dump`. The `ovadm::backup` and
`ovadm::restore` plans, in progress, automate the first two tiers; the tables
below are their specification. OpenVoxDB's data stays a hand step, because
ovadm installs OpenVox Server only and your own Puppet code owns the database.

Two things to know before you start:

- A backup is only useful once it is off the host. Every recipe here writes
  to a directory on the primary server. Copy the result to your backup
  system straight afterwards.
- The archive contains private keys: the CA key, the server's host key, and
  the Hiera eyaml key if you use one. Create it with mode `0600`, keep it on
  encrypted storage, and treat access to it as access to every node the CA
  has signed.

## What a primary server holds

The paths below are the package defaults, which `puppet config print
--section server` reports as `cadir`, `ssldir`, `confdir`, and `codedir`.
Print them before you back up rather than trusting the table. Foreman's
`puppet.conf` snippet, for one, falls back to the Puppet 3 layout,
`vardir = /var/lib/puppet` and `ssldir = $vardir/ssl`, for a host whose
repository parameter it does not recognise as an AIO install, and it knows no
OpenVox parameter. The tables were checked against OpenVox Server 8.17.0 and 9.0.1 on
AlmaLinux 10; on Debian and Ubuntu only the service environment files differ,
as noted.

### Tier 0: irreplaceable

Lose any of these without a backup and the fleet has to be re-enrolled or the
secret re-issued.

| What | Where | Why it matters |
| ---- | ----- | -------------- |
| The CA: signing key and certificate, root key, CRL, serial, inventory, signed certificates, pending requests | `/etc/puppetlabs/puppetserver/ca/` (`cadir`), the whole directory: `ca_key.pem`, `root_key.pem`, `ca_crt.pem`, `ca_pub.pem`, `ca_crl.pem`, `serial`, `inventory.txt`, `infra_crl.pem`, `infra_inventory.txt`, `infra_serials`, `signed/`, `requests/` | Every agent trusts this CA. Without the key, no new node can be signed and no certificate revoked; without `inventory.txt` and `signed/`, the CA no longer knows the certificates it issued. The `infra_*` files drive the [infrastructure CRL](https://docs.openvoxproject.org/openvox-server/latest/infrastructure_crl.html) and are empty placeholders until it is enabled. Owned by `puppet:puppet`, directory `0750`, files `0640`. If the directory is lost, restore it before the next agent run on the server: the openvox_server module recreates a CA when `ca_crt.pem` is missing, and from then on the server presents a certificate no agent trusts until the backup is put back. |
| The server's own certificate and key | `/etc/puppetlabs/puppet/ssl/` (`ssldir`) | Re-issuable from the CA, but restoring it means no re-sign step and no change agents could notice. Also holds the server's copy of the CA bundle and the CRL. `puppet:puppet`. |
| OpenVoxDB's copy of the server certificate | `/etc/puppetlabs/puppetdb/ssl/` | Copies of the files above, made by `puppetdb ssl-setup`. Regenerable from `ssldir`, cheap to keep. `puppetdb:puppetdb`, `0700`. |
| Hiera eyaml keys | The paths that `pkcs7_private_key` and `pkcs7_public_key` name in each environment's `hiera.yaml`, for example `/etc/puppetlabs/eyaml/keys/` or `/etc/puppetlabs/puppet/eyaml/` | Without the private key, every encrypted Hiera value is gone and every secret in your data has to be rotated. Check where yours are: the location is set by your control repository, not by the package. |
| Code deploy key | Wherever r10k is told to find it: an `ssh` config entry, a `private_key` setting in `r10k.yaml`, or `/root/.ssh/` | Re-issuable on the Git server, but nothing deploys until it is. Often outside `/etc/puppetlabs/`, so a backup of that tree alone misses it. |
| Other site secrets | `csr_attributes.yaml` when it carries a pre-shared autosign key, webhook tokens, keys under `/etc/puppetlabs/bolt/` | Each is small and easy to forget. Back up `/etc/puppetlabs/` whole rather than listing them, and add the paths outside it that your site uses. |

### Tier 1: configuration

Small, cheap, and the thing you most often want to roll back after a change
that did not work out.

| What | Where |
| ---- | ----- |
| OpenVox Server settings | `/etc/puppetlabs/puppetserver/conf.d/` (`puppetserver.conf`, `webserver.conf`, `web-routes.conf`, `auth.conf`, `ca.conf`, `global.conf`, `metrics.conf`, `versioned-code.conf` if static catalogs are on), `services.d/ca.cfg`, `logback.xml`, `request-logging.xml` |
| JVM arguments and service settings | `/etc/sysconfig/puppetserver` and `/etc/sysconfig/puppetdb` on Red Hat family systems; `/etc/default/puppetserver` and `/etc/default/puppetdb` on Debian and Ubuntu |
| Puppet settings | `/etc/puppetlabs/puppet/puppet.conf`, `autosign.conf`, `csr_attributes.yaml`, `hiera.yaml` (the global one), `puppetdb.conf`, `routes.yaml`, and `fileserver.conf` and `custom_trusted_oid_mapping.yaml` if present |
| OpenVoxDB settings | `/etc/puppetlabs/puppetdb/conf.d/` (`database.ini` holds the database password, `read_database.ini`, `jetty.ini`, `config.ini`, `auth.conf`), `bootstrap.cfg`, `logback.xml`, `request-logging.xml` |
| Code deployment | `/etc/puppetlabs/r10k/r10k.yaml`, plus whatever runs r10k for you: a systemd service and timer under `/etc/systemd/system/`, a webhook receiver's configuration, or a cron entry |
| Gems added to the server | The output of `puppetserver gem list`, and of `/opt/puppetlabs/puppet/bin/gem list` for the agent's Ruby, where r10k and the eyaml command line tool live. Keep the lists; the gems are reinstalled, not copied. |
| Package versions | `openvox-server`, `openvoxdb`, `openvoxdb-termini`, `openvox-agent`, and the PostgreSQL server package. A restore onto different versions is a migration, not a restore, so record them with the archive. |

Backing up `/etc/puppetlabs/` as one tree covers tiers 0 and 1 together, apart
from the files outside it called out above, and does not go stale when a
version adds a file. Decide what to put back at restore time instead.

If the host is managed by the
[openvox_server](https://forge.puppet.com/modules/miharp/openvox_server) module,
part of tier 1 is desired state: the module writes `webserver.conf` whole,
owns `services.d/ca.cfg`, and sets the `puppet.conf` and `ca.conf` settings it
is given, so those come back on the next agent run whatever a restore put
there. For them, a rollback is a revert in Hiera followed by an agent run. The
restore is for the files the module leaves alone: `auth.conf`,
`puppetserver.conf`, `logback.xml`, `global.conf`, `metrics.conf`,
`web-routes.conf`, and the OpenVoxDB and r10k configuration.

### Tier 2: regenerable

Large, and either reproducible from somewhere else or rebuilt by the agents
on their next run. Back these up when you cannot afford the time or the loss
they imply, not by default.

| What | Where | What happens without it |
| ---- | ----- | ----------------------- |
| Deployed code | `/etc/puppetlabs/code/environments/`, one directory per environment | `r10k deploy environment --modules` rebuilds it from your Git server. Each environment's `.r10k-deploy.json` records the commit (`signature`) and the module versions that were deployed, so keep those files, or the output of `git rev-parse HEAD` per environment, to be able to reproduce the exact state. Back up the tree itself only when your Git server shares the primary's blast radius. |
| r10k cache | `/var/cache/r10k/` | Re-fetched on the next deploy. |
| OpenVoxDB data | The `puppetdb` database in PostgreSQL. The `puppetdb` role owns every table, and `puppetdb-read` is the read-only connection's role. Dumped with `pg_dump`, never copied as files while PostgreSQL runs. | Facts and catalogs come back on each agent's next run. Reports, resource events, and exported resources do not. Sites that rely on exported resources, on report history, or on tools that read OpenVoxDB want this tier. |
| Server runtime data | `/opt/puppetlabs/server/data/puppetserver/` | The node cache (`yaml/`) and the JRuby gem directory regenerate; the file bucket (`bucket/`) matters only if your site uses it, and reports stored there only if you do not send them to OpenVoxDB. Mostly vendored gems that come with the package. |

### What is not here

- **Compilers** hold no unique state: their certificates come from the CA, their
  code from r10k, their configuration from your control repository. A lost
  compiler is rebuilt and re-enrolled; it is not restored.
- **Agents** hold nothing worth keeping. A lost agent re-enrols.
- **PostgreSQL's data directory** is not copied as files. It is only consistent
  when PostgreSQL is stopped, it is tied to the PostgreSQL major version, and
  `pg_dump` gives you a smaller, portable copy of the same thing.
- **Puppet Enterprise's other databases** (classifier, RBAC, orchestrator,
  activity) do not exist on OpenVox. If you are migrating from PE, there is
  nothing to carry over for them.

## Backing up by hand

The commands below run as root on the primary server and produce a timestamped
directory under `/var/backups/openvox`. They do not stop any service: the CA
directory changes only when a certificate is signed or revoked, and `pg_dump`
produces a consistent snapshot on its own.

Record the versions and the state the backup describes:

```console
backup=/var/backups/openvox/$(hostname -f)-$(date +%Y%m%dT%H%M%S)
install -d -m 0700 "$backup"
rpm -q openvox-server openvoxdb openvoxdb-termini openvox-agent postgresql-server > "$backup/versions.txt"
puppetserver gem list > "$backup/puppetserver-gems.txt"
/opt/puppetlabs/puppet/bin/gem list > "$backup/agent-gems.txt"
cat /etc/puppetlabs/puppetserver/ca/serial > "$backup/ca-serial-before"
```

On Debian and Ubuntu, use `dpkg-query -W openvox-server openvoxdb
openvoxdb-termini openvox-agent postgresql` for the versions.

Back up tiers 0 and 1, adding the paths outside `/etc/puppetlabs/` that your
site uses (here, root's SSH directory for the r10k deploy key and the systemd
units that run r10k):

```console
tar --exclude=/etc/puppetlabs/code -czf "$backup/etc-puppetlabs.tar.gz" \
  /etc/puppetlabs \
  /etc/sysconfig/puppetserver /etc/sysconfig/puppetdb \
  /root/.ssh /etc/systemd/system/r10k-deploy.*
```

Record what code was deployed, which is enough to reproduce the environments
with r10k:

```console
for d in /etc/puppetlabs/code/environments/*/; do
  cp "$d/.r10k-deploy.json" "$backup/r10k-deploy-$(basename "$d").json" 2>/dev/null
done
cp /etc/puppetlabs/r10k/r10k.yaml "$backup/"
```

Back up OpenVoxDB with the connection OpenVoxDB itself uses, read from
`database.ini`. This works the same whether PostgreSQL is on the primary or on
another host, and needs no shell on the database server. `pg_dump` comes
with the `postgresql` package on Red Hat family systems and
`postgresql-client` on Debian and Ubuntu; a primary with a local PostgreSQL
already has it.

```console
ini=/etc/puppetlabs/puppetdb/conf.d/database.ini
subname=$(awk -F= '/^subname/ {gsub(/ /,"",$2); print $2}' "$ini")   # //HOST:PORT/DATABASE
export PGPASSWORD=$(awk -F= '/^password/ {gsub(/ /,"",$2); print $2}' "$ini")
host=${subname#//}; host=${host%%[:/]*}
port=$(echo "$subname" | sed -n 's#//[^:/]*:\([0-9]*\)/.*#\1#p'); port=${port:-5432}
db=${subname##*/}
pg_dump -h "$host" -p "$port" -U puppetdb -d "$db" -Fd -Z3 -j4 -f "$backup/openvoxdb"
unset PGPASSWORD
```

The directory format (`-Fd`) with compression (`-Z3`) and four parallel jobs
(`-j4`) is what `pg_restore -j4` reads back fastest. The `puppetdb` role owns
every table, so it can dump and restore the database without superuser
rights; only dropping and recreating the `public` schema before a restore
needs the `postgres` user.

Finally, confirm the CA did not change while you worked, and close the
archive:

```console
cmp "$backup/ca-serial-before" /etc/puppetlabs/puppetserver/ca/serial && rm "$backup/ca-serial-before"
chmod -R go-rwx "$backup"
du -sh "$backup"
```

If `cmp` reports a difference, a certificate was signed during the backup;
run it again.

### How often

Take a backup before every upgrade and after every batch of certificate
signings, and on a schedule that matches how often your fleet changes. A CA
restored from a backup does not know the certificates signed after that
backup was taken; the smaller that set, the simpler the recovery. Tier 2 is
worth including on the schedule only if your site depends on report history
or exported resources.
