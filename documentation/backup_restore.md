# Backing up and restoring OpenVox Server

An OpenVox primary server holds the one thing nothing else in your
infrastructure can replace, the certificate authority, next to configuration
that is cheap to keep and data that the agents rebuild on their own. A good
backup copies the first two every time and the third when you need it. This
page lists what lives on a primary server and why each item matters, how
`ovadm::backup` takes it and `ovadm::restore` puts it back, and how to do the
same by hand with `tar` and `pg_dump`. OpenVoxDB's data stays a hand step
either way, because ovadm installs OpenVox Server only and your own Puppet
code owns the database.

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
`puppet.conf` snippet, for one, falls back to the layout of Debian's own
puppet packages, `vardir = /var/lib/puppet` and `ssldir = $vardir/ssl`, for a
host whose
repository parameter it does not recognise as an AIO install, and it knows no
OpenVox parameter. The tables were checked against OpenVox Server 8.17.0 and
9.0.1 on AlmaLinux 10; on Debian and Ubuntu only the service environment files
differ, as noted.

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

## Backing up with ovadm

`ovadm::backup` takes tiers 0 and 1, and the record of what r10k deployed,
into one archive on the server, checks the archive against its own checksums,
and prints where it is:

```console
bolt plan run ovadm::backup server_host=ovox-server.example.com
```

```text
ovox-server.example.com: /var/backups/openvox/openvox-backup-ovox-server.example.com-20261021T181530Z.tar.gz (0.1 MB, 41 files)
ovox-server.example.com: 44 checksums checked, ok
Copy the archive off the host: it holds the CA private key.
```

The archive is owned by root with mode `0600`, in a directory created `0700`.
Nothing copies it anywhere: that is your backup system's job, and the first
thing to do after the plan returns.

### What goes in

Everything is on unless you switch it off with `backup`:

| Item | What it takes | Switch off with |
| ---- | ------------- | --------------- |
| `ca` | `cadir`, `ssldir` and OpenVoxDB's `ssl/`: tier 0 | `backup='{"ca": false}'` |
| `config` | the rest of `/etc/puppetlabs/` without `code/`, plus the services' environment files under `/etc/sysconfig/` or `/etc/default/`: tier 1 | `backup='{"config": false}'` |
| `code` | each environment's `.r10k-deploy.json` and `hiera.yaml`: enough to redeploy the same commits with r10k, and to find the eyaml keys | `backup='{"code": false}'` |

`include_code_tree=true` takes `/etc/puppetlabs/code/` itself as well, for a
site whose git server could be lost together with the primary.

`extra_paths` adds paths outside the tree, as a list. The r10k deploy key,
the units that run r10k, and the static-catalog scripts under
`/opt/puppetlabs/server/data/puppetserver/scripts/` when `puppetserver.conf`
names them are the usual ones:

```console
bolt plan run ovadm::backup server_host=ovox-server.example.com \
  extra_paths='["/root/.ssh", "/etc/systemd/system/r10k-deploy.service", "/etc/systemd/system/r10k-deploy.timer", "/opt/puppetlabs/server/data/puppetserver/scripts"]'
```

A rebuild from the archive needs every path the server reads before the
site's own code has run again; a backup that misses one is found out then.

The plan warns when an environment's `hiera.yaml` names an eyaml private key
that the archive does not hold, with the path to add.

### What the archive holds

One directory, named like the archive, with:

- `files/`: the paths above as they are on the host, owners and modes
  included
- `ovadm/manifest.json`: when and where the backup was taken; the package
  versions of the agent, server, OpenVoxDB and PostgreSQL; the gems added to
  the server's JRuby and the agent's Ruby; each environment's deployed commit;
  the CA serial before and after the copy; the OpenVoxDB schema version, read
  over the connection in `database.ini`; whether the openvox_server module
  manages the host
- `ovadm/topology.json`: what `ovadm::status` reports as the topology, so a
  restore knows the compilers and the database when the server that knew them
  is gone
- `ovadm/SHA256SUMS`: a checksum for every file above

`ovadm::backup_verify` checks an archive on its own: it unpacks, checks every
checksum and the manifest, and confirms the archive is from the host it runs
on, with the same package versions. The plan runs it after every backup; run
it yourself before a restore, or on a copy you moved somewhere else:

```console
bolt task run ovadm::backup_verify --targets ovox-server.example.com \
  archive=/var/backups/openvox/openvox-backup-ovox-server.example.com-20261021T181530Z.tar.gz
```

### Consistency

The services keep running. The CA directory changes only when a certificate
is signed or revoked, so the plan reads the CA serial before and after the
copy and warns if it moved, in which case take the backup again.
`stop_services=true` stops puppetserver and puppetdb for the copy and starts
them afterwards, for a cold backup.

### Encryption

`age_recipient=<age public key>` encrypts the archive to that key with
[age](https://github.com/FiloSottile/age), which must be installed on the
server, and names it `.tar.gz.age`. The server holds no identity for it,
so the plan does not verify an encrypted archive; run `backup_verify` with
`age_identity`, the path of the identity file, wherever that is. Without
encryption the archive is plain, and it holds the CA private key: keep it on
encrypted storage.

### Scheduling

ovadm does not schedule backups. `backup_create`, the task behind the plan,
is a self-contained script with a default for every input, so a timer or your
backup system can run it: copy `tasks/backup_create.sh` and
`tasks/topology.sh` from the module to the server, side by side, and run the
first as root. A class in the openvox_server module is the planned home for
that timer.

## Restoring with ovadm

`ovadm::restore` puts an archive back on the host it came from:

```console
bolt plan run ovadm::restore server_host=ovox-server.example.com \
  archive=/var/backups/openvox/openvox-backup-ovox-server.example.com-20261021T181530Z.tar.gz
```

In order, it checks the archive (every checksum, that it is from this host,
that the installed `openvox-server` is the version in the manifest), stops
puppetserver and puppetdb, extracts the items in scope with owners and modes
as archived, starts the services, reinstalls gems the manifest lists that the
host lacks, redeploys the code with r10k when `code` is in scope, runs the
agent once so the site's own code converges, and finishes with
`ovadm::status`. Every check stops the plan; `force=true` goes past the ones
about the host (certname, version, and the CA check below), never past a bad
checksum.

Three things to know before the first restore:

- **The certname must match.** An archive restores onto the host whose
  certname it records. Restoring elsewhere is for a rebuilt server with the
  same name, below.
- **Files added since the backup stay.** A restore writes what the archive
  holds; it does not remove a `conf.d` file, a signed certificate or an
  environment that appeared afterwards. The agent run at the end is a
  convenience: if it fails, the plan says so and carries on, since the files
  are back and the services are up by then. Package manager leftovers
  (`*.rpmnew`, `*.rpmsave`, `*.dpkg-dist`, `*.dpkg-old`) in the archive are
  not put back.
- **On a host the openvox_server module manages**, the files it owns
  (`webserver.conf`, `services.d/ca.cfg`, the `puppet.conf` and `ca.conf`
  settings it is given, the JVM sizing) come back on the next agent run,
  which the plan itself triggers. To roll those back, revert the Hiera data
  and let the run do it; the restore is for everything else. The manifest
  says whether the module was in the host's last catalog.

`dry_run=true` lists the files that differ from the archive, and those the
archive has that the host has not, and touches nothing:

```console
bolt plan run ovadm::restore server_host=ovox-server.example.com archive=... dry_run=true
```

`scope` limits the restore to some of what the archive holds: `ca`,
`config`, `code` (the files under `/etc/puppetlabs/code/` the archive has,
followed by an r10k deploy), and `extra` (the `extra_paths` given at backup
time). The default is everything the archive holds.

### Rolling back configuration

A bad change under `conf.d`, a JVM setting that stops the service, an
`auth.conf` rule that locked the compilers out:

```console
bolt plan run ovadm::restore server_host=ovox-server.example.com archive=... scope='["config"]'
```

A minute or two, most of it puppetserver starting. Check the dry run first
when you are not sure which files changed since the backup. The agent run at
the end reapplies the site's code, so a change the site's code makes comes
straight back: that is where it has to be reverted.

### Restoring a lost CA

The CA directory gone, the fleet still up and trusting the same CA
certificate:

```console
bolt plan run ovadm::restore server_host=ovox-server.example.com archive=... scope='["ca"]'
```

This puts back the CA directory, the server's own certificate and key, and
OpenVoxDB's copy of them, and restarts the services. Agents never notice: the
CA certificate they hold is the one restored.

What the loss looks like, on OpenVox Server 8.17: a running puppetserver
crashes within a minute of its CA directory disappearing (it rewrites
`infra_serials` there regularly), systemd starts it again, and it goes on
serving catalogs with its own certificate, with signing and revocation
broken. The openvox_server module's next agent run tries `puppetserver ca
setup`, which refuses while the server's own certificate exists, so that
run fails and changes nothing. Lose `ssldir` as well and puppetserver
cannot start at all: as the `puppet` user it cannot recreate `ssldir` under
the root-owned `confdir`, so systemd restarts it in a loop until the restore
puts the files back. In neither state does the server make itself a new CA.
Should a new one appear anyway, from a hand-run `puppetserver ca setup` or
a first-start elsewhere, the restore replaces it with the archived one and
warns that it did.

A CA restored from a backup does not know the certificates signed after it
was taken. The plan compares the live `inventory.txt` with the archive's and
refuses to go on if the live CA has signed certificates the archive lacks,
naming them. With `force=true` it restores anyway; afterwards, remove those
hosts' certificates (`puppetserver ca clean --certname <host>` will not know
them, so delete `signed/<host>.pem` by hand, and `ssldir` on the host) and
enrol them again with `ovadm::add_agent`. Their serial numbers are reused by
the restored CA, which is why their files must go. The smaller that set, the
simpler the recovery, which is why backups follow signings.

### Rebuilding the server on a new host

The server is gone. Build a replacement with the same certname and the
address the agents use, then:

1. **Install OpenVox Server with the versions the archive records.** Run
   `ovadm::restore` against the bare host and it stops with the exact
   command, read from the manifest:

   ```text
   openvox-server is not installed; install it first, then restore: bolt plan run ovadm::install server_host=<this host> ovox_server_version=8.17.0 ovox_version=8.30.0
   ```

   That install makes a throwaway CA and certificate; the restore replaces
   them.
2. **Restore the archive with `rebuild=true`**, uploading it from wherever
   the backups are kept:

   ```console
   bolt plan run ovadm::restore server_host=ovox-server.example.com rebuild=true \
     source=/backups/openvox-backup-ovox-server.example.com-20261021T181530Z.tar.gz \
     archive=/var/backups/openvox/openvox-backup-ovox-server.example.com-20261021T181530Z.tar.gz
   ```

   `rebuild` orders the restore the way the server was first built. The
   first pass puts back everything but `puppet.conf`, `puppetdb.conf` and
   `routes.yaml`, the three files that wire the server to OpenVoxDB (the
   plan warns that the throwaway CA is replaced); installs the gems the
   manifest lists (r10k among them, when the site installed it by hand);
   redeploys the code; and runs the agent on a server still wired as
   `ovadm::install` left it. That run is where the site's own code brings
   back what it owns: OpenVoxDB and PostgreSQL, the r10k timer, the
   firewall. A site whose code queries PuppetDB at compile time would fail
   that run with the terminus in place, which is why those files wait. The
   second pass then puts the configuration back whole, installs
   `openvoxdb-termini` if the site's code did not (the restored
   `routes.yaml` needs it), restarts, and runs the agent again. Expect the
   first run to take a while and to report changes; the second should be
   clean.
3. **Files of users that did not exist yet** are put back under their old
   numeric ids and the plan says which: on a host without OpenVoxDB that is
   everything under `/etc/puppetlabs/puppetdb/`. The package creates the
   user on install, and the module that manages OpenVoxDB sets the owners
   when it runs; if nothing does, `chown -R puppetdb:puppetdb` them.
4. **The agents' next run exits 0** with the certificates they had: the CA
   is the same, the server's certificate is the same, nothing was
   re-issued.
5. **OpenVoxDB's data** is not in the archive. Facts and catalogs come back
   on each agent's next run; for reports and exported resources, restore a
   `pg_dump` taken with the recipe below, after the site's code has created
   the empty database.

### An upgrade gone wrong

`ovadm::upgrade` takes a backup of the server before it touches a package
and prints the archive's path. The way back is the previous packages, then
that archive:

1. **Put the previous packages back.** ovadm does not downgrade. On the
   server, with the previous major's repository in place again when the
   upgrade crossed one:

   ```console
   dnf downgrade openvox-server-8.17.0 openvox-agent-8.31.0        # EL
   apt-get install openvox-server=8.17.0-1+ubuntu24.04 ...          # Debian, Ubuntu
   ```

   The versions are in the archive's manifest, and `ovadm::backup_verify`
   prints them next to the host's. `ovadm::restore` refuses the archive
   while the installed `openvox-server` is not the version in the manifest,
   which is the check that keeps you from restoring 8's configuration onto
   a 9 server; `dry_run=true force=true` still shows what it would change.
2. **Restore the archive**:

   ```console
   bolt plan run ovadm::restore server_host=ovox-server.example.com \
     archive=/var/backups/openvox/openvox-backup-ovox-server.example.com-20261022T120000Z.tar.gz
   ```

   Configuration the upgrade rewrote comes back, the CA and certificates
   are as they were (an upgrade does not change them, so the restore
   reports them unchanged), and the agent run at the end lets the site's
   code settle. Downgrade OpenVoxDB with the server when the upgrade moved
   it, by hand, as the upgrade page says.

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
