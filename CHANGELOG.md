# Changelog

Notable changes to ovadm are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) — while ovadm is in
0.x, a minor version may carry breaking changes.

## [Unreleased]

## [0.14.0] - 2026-11-12

### Added

- `ovadm::extend_ca` plan: extends the CA certificate, before or after it
  has expired, by re-signing it with the same key and a later end date, so
  every certificate the CA issued stays valid. It handles a root with an
  intermediate and a single self-signed certificate, re-signs the CA's CRLs
  (a root's CRL is written once at setup and expires with the root), takes a
  backup first, stops and starts the server, gives each compiler the new
  bundle and a restart, and pushes the bundle to the hosts named in
  `agent_hosts`. When the server's own certificate has expired with the CA,
  as it does on a CA puppetserver generated for itself, the plan replaces
  it and keeps its subject alternative names. `dry_run` reports what would
  change; `distribute_only` pushes the current bundle to hosts an earlier
  run left out. See `documentation/extend_ca.md` (#117).
- `ovadm::ca_expiry`, `ovadm::ca_extend`, `ovadm::ca_bundle_install` and
  `ovadm::server_cert_regen` tasks, which the plan runs and which can be
  used one at a time (#117).

### Changed

- `ovadm::status` reports when each CA certificate and the host's own
  certificate expire, and warns when a CA certificate has less than a year
  left, when a CRL or the host's certificate has less than 30 days, and when
  the server's or OpenVoxDB's copy of the CA is not the one in the CA
  directory. The result gains `ca_expiry` (#117).

## [0.13.0] - 2026-11-10

### Changed

- `ovadm::upgrade` disables the Puppet agent on the server and on every
  compiler named, for the whole upgrade, and enables it again at the end,
  on the failure path too. It used to be disabled only on the server, and
  only while the pre-upgrade backup copied files, so a scheduled run could
  apply the site's code to a server in the middle of the upgrade: with a
  version or collection pin, that moved a package back, or a compiler ahead
  of the server. The plan waits up to five minutes for a run under way
  before it starts and upgrades nothing if one does not finish. An agent
  that was already disabled stays disabled, and one an interrupted run of
  the plan left disabled is enabled by the next run. The result gains
  `agents_held` (#114).
- `documentation/upgrade.md` says what a site whose code pins the server's
  version or collection does so the first agent run after the upgrade does
  not undo it: deploy the new pin, then run the plan (#114).

### Added

- `ovadm::agent_disable` and `ovadm::agent_enable` tasks: disable the agent
  with a message and wait for a run under way, then enable it again.
  `agent_disable` reports whether it was the one to disable the agent, and
  ignores a run lock whose process is gone (#114).

## [0.12.0] - 2026-11-09

### Changed

- `backup_create` checksums the CA's `serial`, `ca_crl.pem` and
  `inventory.txt` before and after the copy, where it used to read `serial`
  alone. A revocation changes `ca_crl.pem` and leaves `serial` where it was,
  so a certificate revoked during the copy went unnoticed. The result and
  the manifest gain `ca_changed` and `ca_changed_files`; `ca_serial_moved`
  stays. The warning from `ovadm::backup` names the files that changed
  (#112).
- `wait_until_service_ready` takes `puppetdb=true` to wait for OpenVoxDB as
  well, on the plain-text port its `jetty.ini` names. The result lists the
  `services` it waited for, and a timeout names the one that did not answer.
  `ovadm::restore` asks for it when the copy stopped puppetdb, so the agent
  run that follows does not fail on report submission (#112).

### Fixed

- `backup_restore`, on a host whose CA directory is gone, reads OpenVoxDB's
  plain-text port from `jetty.ini` for the node list it compares with the
  archive's inventory. It assumed 8080, so on a host with the port moved the
  comparison was skipped. The warning names the port it tried (#112).
- The by-hand recipes in `documentation/backup_restore.md` are the ones on
  the OpenVox docs page as merged: one script under `set -euo pipefail`,
  `database.ini` parsed with `sed` (a password containing `=` survives) and
  its user and database names used, the three-file CA check, a
  configuration rollback that leaves the CA and the certificates alone, and
  status checks that gate the agent start and read the OpenVoxDB port from
  `jetty.ini` (#112).

## [0.11.0] - 2026-11-02

### Changed

- `backup_create` and `backup_restore` disable the agent while the files are
  copied (`puppet agent --disable`), wait up to five minutes for a run that
  is already under way, and enable it again when they finish, on every exit
  path. An agent the operator had disabled before stays disabled. Without
  this, a scheduled run could change files under `tar` during a backup, or
  apply the site's code over files still being put back during a restore,
  before the plan's own agent run. Both tasks report `agent_disabled` (#107).
- `backup_create` checks the free space under `destination` before it copies
  anything (twice the size of the paths, since the staging copy and the
  archive sit side by side for a moment) and `backup_restore` checks the
  space beside the archive against its uncompressed size before unpacking;
  both refuse with the two sizes in the message rather than failing part
  way. A file that changes or disappears while `tar` reads it no longer
  fails the backup: the copy holds what `tar` saw, the warning names the
  file, and the CA `serial` check still speaks for the one directory that
  changes on its own (#108).

## [0.10.0] - 2026-11-01

### Added

- `ovadm::backup` takes the static catalog commands that `conf.d` names
  (`code-id-command` and `code-content-command`, usually under
  `/opt/puppetlabs/server/data/puppetserver/scripts/`) with the configuration,
  and records them in the manifest as `static_catalog_scripts`;
  `ovadm::restore` puts them back with the `config` scope. A restored
  `conf.d` points at them, and OpenVox Server compiles nothing while they
  are missing, not even the agent run that would recreate them, so a backup
  that left them to `extra_paths` could not finish a rebuild (#101).
- `ovadm::restore` compares the archive's revocation list with the live
  one and refuses, unless forced, when the CA has revoked certificates
  since the backup: the restored `ca_crl.pem` is the archive's, so those
  certificates would be valid again. The warning after a forced restore
  names them and the `puppetserver ca revoke` command to run (#99).
- `ovadm::restore` on a host whose CA directory is gone compares OpenVoxDB's
  node list with the archive's inventory and names the nodes the archive
  does not know, which is as close as the host can get to "who enrolled
  since the backup" once the inventory is lost (#102).

### Changed

- `ovadm::restore rebuild=true` no longer holds back `puppet.conf` whole.
  The first pass puts the file back and takes only `storeconfigs`,
  `storeconfigs_backend` and `reports` out of it (`backup_restore`'s new
  `strip_openvoxdb_settings`), so the agent run that brings OpenVoxDB back
  keeps the certname, server, environment and `dns_alt_names` the archive
  recorded. Held back whole, the run used the default environment and, on
  a host whose certname differs from its FQDN, the server could not have
  started (#100).
- The warning after a forced CA restore no longer says to clean the
  certificates signed since the backup: it says to delete their
  `signed/<name>.pem` by hand and enrol the hosts again, and not to use
  `puppetserver ca clean`, which works on such a certificate and revokes a
  serial the restored CA is about to reissue, so the next certificate
  with that serial is revoked from the start (#98).
- `documentation/backup_restore.md` corrected from the lab run of the
  openvox-docs page built on it: the tier 0 table no longer says the
  openvox_server module recreates a missing CA (its `puppetserver ca setup`
  refuses while the server's own certificate exists), the by-hand recipes
  include the static catalog scripts, a status check and the OpenVoxDB
  schema reset as a heredoc, and the lost-CA and rebuild by-hand
  procedures point at the docs page that carries them step by step (#103).

## [0.9.0] - 2026-10-29

### Added

- `ovadm::configure_repo` installs the `redhatfips` release package on an
  Enterprise Linux host in FIPS mode, so every plan uses the packages OpenVox
  builds for such hosts; a `fips` parameter overrides the detection, and the
  result reports the `platform`. The precheck fails on a FIPS host where
  OpenVox Server 9's launcher would run a Java other than 21, the only Java
  the `redhatfips` packages support, and `ovadm::select_java` accepts only 21
  there. Documented in "FIPS mode" of `documentation/install.md`.

### Fixed

- `ovadm::restore` with `rebuild` on a server that uses static catalogs:
  the first pass also leaves out `conf.d/versioned-code.conf`, whose
  commands the site's code may be what installs (codavox's, for one).
  Put back before them, it made OpenVox Server refuse every compile,
  including the agent run that would have installed them, and the rebuild
  could not finish. The second pass puts it back with the rest of the
  configuration.
- `ovadm::restore` installs `git` before the r10k deploy when the host
  lacks it, as a rebuilt host does until the site's code runs, so r10k no
  longer stops with "No Git providers are functional"; and, with `source`,
  installs `tar` before the upload, which a stock image may not have.
- `ovadm::backup_restore` makes the directories it has to create on the
  way to a restored path `0755`, as the host's own would be. They came back
  root-only, so an extra path under a directory the host did not have yet
  (codavox's provenance log on a rebuilt host, before the codavox package)
  left OpenVox Server unable to run codavox's static-catalog commands.

## [0.8.0] - 2026-10-22

### Added

- `ovadm::backup` backs up a primary server into one archive under
  `/var/backups/openvox`: the CA directory and the server's certificates,
  the rest of `/etc/puppetlabs/` without `code/` and the services'
  environment files, and each environment's `.r10k-deploy.json` and
  `hiera.yaml`, with owners and modes kept. Each item can be switched off
  with `backup`, `include_code_tree` takes the code directory too, and
  `extra_paths` adds paths outside the tree such as the r10k deploy key.
  The archive carries a manifest (versions, gems, deployed commits, CA
  serial before and after the copy, OpenVoxDB schema version, whether the
  openvox_server module manages the host), the topology `ovadm::status`
  reports, and a checksum of every file; the plan runs
  `ovadm::backup_verify` on it afterwards and warns when an environment's
  eyaml key is not in the archive, or the CA changed during the copy.
  `stop_services` gives a cold backup and `age_recipient` an encrypted one.
  OpenVoxDB's data is not an item: the page carries the `pg_dump` recipe
  ([#89](https://github.com/miharp/ovadm/issues/89)).
- `ovadm::restore` puts an archive back on the host it came from, all of it
  or by `scope` (`ca`, `config`, `code`, `extra`): it verifies the archive,
  refuses one from another certname or openvox-server version, and, with
  the CA in scope, one the host's CA has outgrown by signing certificates
  since the backup, naming them (`force` goes past the host checks, never a
  bad checksum); stops puppetserver and puppetdb, extracts with owners and
  modes as archived and leaves package manager leftovers and files added
  since the backup alone, starts the services, reinstalls gems the manifest
  lists, redeploys the code with r10k when in scope, runs the agent once and
  reports the status. `dry_run` lists what would change; `source` uploads
  the archive from the workstation first, for a rebuilt host, where the
  plan also names the exact `ovadm::install` command to run first, and
  `rebuild=true` restores everything but `puppet.conf`, `puppetdb.conf`
  and `routes.yaml` first, runs the agent so the site's code brings
  OpenVoxDB back, and only then the configuration whole, installing
  `openvoxdb-termini` when the host still lacks it. The `code` item carries `/etc/puppetlabs/r10k/` with it. The new
  `ovadm::backup_restore` task does the host side and reports changed and
  missing files ([#89](https://github.com/miharp/ovadm/issues/89)).
- `ovadm::upgrade` takes a backup of the server before it touches a
  package, `ovadm::backup` with its defaults under `/var/backups/openvox`,
  and prints the archive's path; `backup_destination` and
  `backup_extra_paths` shape it, `skip_backup` skips it. The plan returns
  the path per server as `backup`.
- `ovadm::status` reports the topology the server's own files describe:
  whether it holds the CA, the compilers (signed certificates carrying
  `pp_role=openvox_compiler`), where it sends OpenVoxDB traffic, and the
  OpenVoxDB database and PostgreSQL on the host, through the new
  `ovadm::topology` task.
- `documentation/backup_restore.md`: what a primary server holds, in three
  tiers, with owners and modes; how to back it up with `ovadm::backup` and
  by hand with `tar` and `pg_dump`.

### Changed

- `ovadm::configure_puppet_conf` keeps the directory settings of an existing
  `[main]` section (`vardir`, `ssldir`, `logdir`, `rundir`, `codedir` and
  the SSL subdirectories) when it rewrites `puppet.conf`, and reports them as
  `kept`. It used to replace the file, so a host Foreman had provisioned with
  its fallback layout (certificates under `/var/lib/puppet/ssl`) lost the
  relocation and requested a new certificate under a certname the CA already
  held. `ovadm::set_csr_attributes` finds `csr_attributes.yaml` through the
  agent's `csr_attributes` setting instead of assuming the default path
  ([#92](https://github.com/miharp/ovadm/pull/92)).

## [0.7.1] - 2026-10-15

### Fixed

- `ovadm::set_csr_attributes`, which `ovadm::install`, `ovadm::add_compiler`
  and `ovadm::add_agent` (given `pp_role`) run before a host's first
  certificate request, sets `pp_role` in an existing `csr_attributes.yaml`
  and keeps the rest of the file, owner and mode included. It used to
  replace the file, dropping a `challengePassword` that a policy-based
  autosign setup had put there for the CA to check, and any extensions of
  the site's own. A role the file already has, under `pp_role` or its OID,
  is replaced and reported as `previous_pp_role`; a file the agent could not
  read either is left as it is and fails the task. The merge needs the
  agent's Ruby, which every host has by the time ovadm writes the file. The
  role is now quoted in the file, so YAML reads one like `1.10` or `on` as a
  string, and the task takes only the role values `add_agent` does
  ([#85](https://github.com/miharp/ovadm/issues/85)).

## [0.7.0] - 2026-10-13

### Added

- `ovadm::add_agent`: install `openvox-agent` on stock hosts from the
  workstation, point them at the server, a compiler or a load balancer
  (`agent_server`), sign their certificates on the server and run each
  agent once, so every host applies its first catalog inside the plan. The
  agents get the newest agent of the major the server runs unless
  `ovox_version` says otherwise; `environment` and the mirror parameters
  work as on `add_compiler`. `pp_role` puts a role in the agents'
  certificates, for sites that classify on
  `$trusted['extensions']['pp_role']`; ovadm's own `openvox_server` and
  `openvox_compiler` are refused. The plan reports the server each agent's
  `puppet.conf` names after its first catalog, and warns where the site's
  code changed it from `agent_server`. A host that fails a step is left out
  of the following ones and reported at the end with the hosts that got
  through, so one bad host does not stop a batch. Two new subplans,
  `agent_package` and `agent_enroll`, carry the steps
  ([#79](https://github.com/miharp/ovadm/issues/79)).
- `precheck` takes `role`: `agent` checks the OS family and time sync only,
  since an agent needs no Java, heap memory or open 8140.

### Changed

- `ovadm::install` and `ovadm::add_compiler` stop when a compiler's first
  catalog run, inside the plan, applies no catalog, whether the environment
  is missing, the catalog fails to compile or a resource fails. They used to
  go on to configure SSL and start puppetserver on a compiler the site's
  code never configured, and report success; the `agent_runonce` task exits
  0 whatever the agent did, and the plans never read its status. The other
  compilers are still enrolled first and the failure names each one that
  failed; none of them gets SSL configured or puppetserver started, and
  `ovadm::add_compiler` for the same compilers finishes the job once the
  cause is fixed. Found on the Hetzner lab, where `add_compiler` with an environment not
  yet deployed reported "Compiler(s) added to the pool."

### Fixed

- A compiler enrolled with `environment` before that environment existed on
  the server stayed on `production`. The compiler's first runs, inside
  `ovadm::install` and `ovadm::add_compiler`, asked for the environment in
  `puppet.conf`; the server, not having it, assigned `production`, and the
  agent then kept the assigned environment over the configured one on every
  later run, so the plan reported success and the compiler applied the
  wrong code. The `agent_runonce` task now takes `environment`, and
  `cert_setup` passes the plan's `environment` to both runs as
  `--environment`: the agent asks for that environment only, and the run
  fails if the server does not have it yet. Found on the Hetzner lab, where
  r10k deployed `demo` a few minutes after the install
  ([#80](https://github.com/miharp/ovadm/issues/80)).

## [0.6.0] - 2026-10-12

### Added

- `environment` on `ovadm::install` and `ovadm::add_compiler`: the Puppet
  environment the nodes' agents ask for, written to the `[agent]` section
  of `puppet.conf` before the first run. Without it a compiler's first run,
  which happens inside the plan, applies `production`; on a site whose pins
  for the deployment live in another environment that run moved the
  compiler back to the other major (OpenVox 9 server, `production` on 8:
  the compiler ended on 8.17.0). Found on the Hetzner lab.

### Changed

- `documentation/add_compiler.md` lists what a compiler still needs from the
  site after the plan: classification, the environment, the PuppetDB
  terminus and OpenVoxDB's port open on the server, code, Hiera secrets.

### Fixed

- `ovadm::add_compiler` no longer stops when the server has already signed
  the compiler's certificate, as it has when the CA autosigns or the
  compiler is being enrolled again. The `sign_csr` task meant to report
  `already_signed` in that case, but checked with `puppetserver ca list
  --signed`, a flag the command does not have, so the check never matched
  and the plan failed after the compiler's first agent run with "No
  certificate request found". It now checks `puppetserver ca list --all`.
  Found on the Hetzner lab, where the master autosigns.

## [0.5.1] - 2026-10-07

### Fixed

- `apt_base_url` and `yum_base_url` now point nodes at the mirror. They used
  to change only where the release package was downloaded from: its
  repository file still named `apt.voxpupuli.org` or `yum.voxpupuli.org`, so
  nodes installed from the public site, and air-gapped ones could not install
  at all. `configure_repo` now points the repository file at the base URL
  given, which must be a mirror with the public site's layout
  ([#70](https://github.com/miharp/ovadm/issues/70)).
- `configure_repo` keeps a repository file edited on a Debian or Ubuntu node
  when the release package ships a new one, instead of failing on dpkg's
  question about it, as `install_server` does since 0.4.1.
- `ovadm::add_compiler` gives the compilers the `openvox-server` version the
  server runs when no version is given. It used to set up the OpenVox 8
  repository and install the newest release there, whatever the server ran,
  so a deployment upgraded to OpenVox 9 got OpenVox 8 compilers. It stops
  when the server still runs Puppet Server
  ([#69](https://github.com/miharp/ovadm/issues/69)).

## [0.5.0] - 2026-10-06

### Added

- `precheck` checks that a host has enough memory for OpenVox Server's heap:
  at least 1.1 times `-Xmx`, which OpenVox Server checks at startup. It uses
  the `-Xmx` in `JAVA_ARGS` where the service's defaults file sets one, and
  the packaged 2 GB heap on a host without OpenVox Server yet, which needs
  2,253 MB. Below that, `ovadm::install` used to fail only when
  `wait_until_service_ready` timed out after five minutes.
- Documentation on sizing the server and compilers after an install, with
  [miharp-openvox_tune](https://forge.puppet.com/modules/miharp/openvox_tune),
  and a README section on the related modules: openvox_tune for sizing and
  [miharp-openvox_agent](https://forge.puppet.com/modules/miharp/openvox_agent)
  for agent upgrades.

- `ovadm::upgrade` upgrades to a new major version (OpenVox 8 to 9) and from
  Puppet Server to OpenVox (Puppet 7 to OpenVox 8), where it used to need the
  repository switched by hand and handled neither the Java change nor a
  `puppetserver` host. The target major version comes from
  `ovox_server_version`, or from the new `ovox_major` parameter when upgrading
  from `package_url` alone. For each node that is behind, the plan switches the
  package repository, installs, selects a supported Java, and restarts. Nodes
  already on the target major keep their repository, so a re-run after a
  failure is safe. The plan refuses to downgrade or to skip a major version.
  See [documentation/upgrade.md](documentation/upgrade.md#major-version-upgrades)
  ([#60](https://github.com/miharp/ovadm/issues/60)).
- `ovadm::upgrade` takes `apt_base_url` and `yum_base_url`, for nodes moving
  to a new major version's repository through a mirror.
- `select_java` task: on OpenVox Server 8, points the `java` alternative at
  Java 17 or 21 when the default is neither. A host upgraded from Puppet Server
  7 on Java 8 or 11 otherwise fails at startup with
  `UnsupportedClassVersionError`. OpenVox Server 9 packages pick their Java
  through a launcher that ignores the alternative, so there the task leaves it
  alone and checks what the launcher runs instead: that it finds a Java, and
  that a `JAVA_BIN` set in the defaults file, which the launcher uses as it
  is, is not older than Java 21.
- CI: an install-test job upgrades an Ubuntu 22.04 Puppet Server 7 host, with
  Java 11 pinned, an edited `JAVA_ARGS` and a custom `codedir`, to OpenVox 8.

### Changed

- When `wait_until_service_ready` times out, its error says why: the
  service's state and the last error puppetserver logged, with the exception
  after it, such as its startup memory check's "Not enough available RAM".
  It used to report only a timeout.
- `configure_repo` removes the release packages of other OpenVox and Puppet
  major versions (`openvox7-release`, `puppet7-release`, and so on), and lists
  them in its result as `removed`. On Debian and Ubuntu the old OpenVox one
  made `dpkg` refuse the new one.
- `install_server` keeps `puppet.conf` when `openvox-server` replaces
  `puppetserver`. The package's install hook treats that as a fresh install and
  resets `vardir`, `logdir`, `rundir`, `pidfile` and `codedir` in `[server]`.
- `get_version` also reports `puppetserver`, and says which package it found
  in a new `package` field. `ovadm::status` labels a host still on Puppet
  Server as such.
- `precheck` takes `upgrade`; with it, a default Java below the supported
  versions is a warning instead of a failure, since the upgrade selects one.
  `ovadm::upgrade` sets it.
- `ovadm::upgrade` fails on a node that has neither `openvox-server` nor
  `puppetserver` installed, pointing at `ovadm::install`, instead of installing
  the package there.

### Fixed

- `precheck`, and so `ovadm::status`, checked the system `java` against 17
  and 21 on OpenVox Server 9 hosts too, so it failed a healthy server whose
  default Java is 25, as on Rocky 9. Where OpenVox Server 9's Java launcher
  is installed, it now checks the Java the launcher runs, 21 or 25. Before
  an install of or upgrade to 9, which the plans now pass as `ovox_major`,
  it does not check the system `java`, since the package brings Java 21.

## [0.4.1] - 2026-09-30

### Added

- `REFERENCE.md`: every plan and task with its parameters, generated from the
  code, shipped in the package so the Forge shows a Reference tab. CI fails when
  it is out of date. Subplans are marked `@api private`.
- Parameter documentation for `apt_base_url`, `yum_base_url` and `package_url`
  on `ovadm::install`, which `bolt plan show` previously listed with no
  description.

### Fixed

- `install_server` no longer fails on Debian and Ubuntu when the operator has
  edited a configuration file that the new package also changes, such as
  `JAVA_ARGS` in `/etc/default/puppetserver` (changed between 8.8.0 and
  8.16.0). dpkg prompted, read end-of-file from Bolt, and left `openvox-server`
  unpacked but not configured, after the old version was already removed. The
  edited file is now kept and the package's version is written beside it as
  `.dpkg-dist`. Part of
  [#60](https://github.com/miharp/ovadm/issues/60).

## [0.4.0] - 2026-09-20

### Removed

- **Breaking:** `ovadm::codavox` and its tasks (`install_codavox`,
  `configure_codavox`, `wire_codavox`, `verify_fleet`, `seed_environment`,
  `wait_for_environment`). Setting up code distribution is a day-2 concern
  outside what ovadm does, the same line it already draws at OpenVoxDB, and the
  plan duplicated in shell what the
  [codavox Puppet module](https://github.com/miharp/puppet-codavox) does
  declaratively. Deployments wired by the plan keep working; manage them with
  that module from here on. ovadm now installs packages only from the Vox Pupuli
  repositories.

## [0.3.0] - 2026-09-20

First release on the Puppet Forge.

### Added

- ovadm is published to the [Puppet Forge](https://forge.puppet.com/modules/miharp/ovadm)
  as `miharp-ovadm`. Pushing a release tag now runs Vox Pupuli's shared release
  workflow, which uploads the module to the Forge and attaches the same tarball
  to the GitHub release; a `Puppetfile` can pin either source. The existing
  gates still run first, and the release notes still come from this file. CI
  builds the package on every pull request.
- `metadata.json` declares the platforms ovadm is tested on: Rocky 9,
  AlmaLinux 9 and 10, Ubuntu 22.04 and 24.04, Debian 12.
- `ovadm::status` reports ovadm's own version, read from `metadata.json`, so a
  deployment can say which ovadm is reporting on it. The per-target line for the
  installed server version is now labelled `OpenVox Server:`.
- README badges for CI, the install test, the latest release, and the license.
- The precheck warns when firewalld or ufw is active on a target without a rule
  allowing 8140/tcp. The install succeeds on such a host, because readiness is
  probed on localhost, while agents and compilers are refused; the warning names
  the command that opens the port. It never fails the plan.
- `CONTRIBUTING.md` documents testing on real VMs, and the install guide covers
  the host firewall and SELinux.

### Fixed

- `LICENSE` now carries the verbatim Apache-2.0 text. The file had been reworded
  — 124 of its ~200 lines differed from the canonical text, the appendix was
  missing, and the definitions of "Work" and "Contribution" had been altered — so
  GitHub reported the repository's license as NOASSERTION despite `metadata.json`
  declaring Apache-2.0.

## [0.2.0] - 2026-09-15

First tagged release. ovadm has been usable from a checkout since May 2026; this
is the point where a deployment can name the version that built it. There was no
0.1.0 release — the version in `metadata.json` never moved off it — so this entry
covers the module as it stands.

### Changed

- **The CA is now created by `puppetserver ca setup` before the first service
  start**, the way the Puppet Enterprise installer does it, producing a root plus
  intermediate signing pair valid for 15 years. Previously `ovadm::install` let
  puppetserver generate its own CA on first start, which yields a single
  self-signed certificate, no root key, and a lifetime of `ca_ttl` — 5 years by
  default, expiring together with the first agent certificates it signed.
  `dns_alt_names` are passed to setup as `--subject-alt-names` rather than relying
  on `puppet.conf` being read on first start.

  Existing deployments are unaffected: setup is skipped whenever `ca_crt.pem`
  exists, so reruns and upgrades never disturb a CA that is already there. Servers
  installed before this release keep their single self-signed CA — see
  [the CA](documentation/install.md#the-ca) for how to tell the two layouts apart.

### Added

- `ovadm::install` — Standard (single node) and Large (server plus compiler pool)
  topologies, with prechecks for OS, Java, port 8140 and NTP.
- `ovadm::upgrade` — in-place upgrade of a server and its compilers.
- `ovadm::status` — prechecks, service state and installed OpenVox version.
- `ovadm::add_compiler` — add a compiler to an existing deployment.
- `ovadm::codavox` — install and wire [codavox](https://github.com/miharp/codavox)
  for versioned code distribution, then verify the fleet converged on one
  `code_id`.
- Opt-in certificate auto-renewal at install time (`enable_cert_auto_renewal`,
  `auto_renewal_cert_ttl`).
- `pp_role` trusted certificate extensions (`openvox_server`, `openvox_compiler`)
  via `csr_attributes.yaml`, for classification without a node classifier.
- Internal package mirrors (`apt_base_url`, `yum_base_url`) and direct artifact
  installs (`package_url`).
- Separate `ovox_version` (agent) and `ovox_server_version` (server) parameters.
- CI: plan unit tests, acceptance tests on Rocky 9, Ubuntu 22.04, Ubuntu 24.04 and
  Debian 12, and an end-to-end install test covering both topologies.

[Unreleased]: https://github.com/miharp/ovadm/compare/v0.14.0...HEAD
[0.14.0]: https://github.com/miharp/ovadm/compare/v0.13.0...v0.14.0
[0.13.0]: https://github.com/miharp/ovadm/compare/v0.12.0...v0.13.0
[0.12.0]: https://github.com/miharp/ovadm/compare/v0.11.0...v0.12.0
[0.11.0]: https://github.com/miharp/ovadm/compare/v0.10.0...v0.11.0
[0.10.0]: https://github.com/miharp/ovadm/compare/v0.9.0...v0.10.0
[0.9.0]: https://github.com/miharp/ovadm/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/miharp/ovadm/compare/v0.7.1...v0.8.0
[0.7.1]: https://github.com/miharp/ovadm/compare/v0.7.0...v0.7.1
[0.7.0]: https://github.com/miharp/ovadm/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/miharp/ovadm/compare/v0.5.1...v0.6.0
[0.5.1]: https://github.com/miharp/ovadm/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/miharp/ovadm/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/miharp/ovadm/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/miharp/ovadm/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/miharp/ovadm/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/miharp/ovadm/releases/tag/v0.2.0
