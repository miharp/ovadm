# Upgrading OpenVox Server with ovadm

## Standard topology

```bash
bolt plan run ovadm::upgrade \
  server_host=ovox-server.example.com \
  ovox_server_version=8.13.0
```

The plan installs the target version, makes sure the default Java is one the new version supports, restarts the service, waits for readiness, and reports the installed version. The `openvox-agent` package is managed by the server package's dependency — the package manager will satisfy it automatically.

The same command upgrades to a new major version, or from Puppet Server to OpenVox; see [Major version upgrades](#major-version-upgrades).

## Edited configuration files

Configuration files you have edited are kept. When the new package ships a different version of one, it is written beside yours for you to compare: `.dpkg-dist` on Debian and Ubuntu (for example `/etc/default/puppetserver.dpkg-dist`), `.rpmnew` on EL. Files you have not edited are replaced by the new version.

## Large topology

```bash
bolt plan run ovadm::upgrade \
  server_host=ovox-server.example.com \
  compiler_hosts=ovox-compiler01.example.com,ovox-compiler02.example.com \
  ovox_server_version=8.13.0
```

The server is upgraded first, then all compilers. Compilers are currently upgraded simultaneously — plan for a brief compilation outage during the compiler restart window, or take them out of your load balancer rotation beforehand.

## Internal package mirror

Within a major version, no flag is needed: the plan installs from the repository configured at install time, so nodes pointed at an internal mirror keep using it.

A node moving to a new major version gets that version's release package, which is downloaded from `https://apt.voxpupuli.org` or `https://yum.voxpupuli.org` unless you pass `apt_base_url` or `yum_base_url` with the same values you gave `ovadm::install`.

## Upgrading from a direct package URL

To upgrade using a specific package artifact without a repo — useful for pre-release builds — pass `package_url` instead of `ovox_server_version`:

```bash
bolt plan run ovadm::upgrade \
  server_host=ovox-server.example.com \
  package_url=https://s3.example.com/openvox-server-9.0.0-....el9.noarch.rpm
```

`ovox_server_version` is optional when `package_url` is provided. The plan will fail if neither is given.

## Using a parameter file

```bash
cp examples/upgrade.json my-upgrade.json
# set ovox_server_version and your hostnames
bolt plan run ovadm::upgrade --params @my-upgrade.json
```

Example contents of `examples/upgrade.json`:

```json
{
  "server_host": "ovox-server.example.com",
  "ovox_server_version": "8.13.0"
}
```

Add `compiler_hosts` as needed.

## Major version upgrades

Upgrading to a new major version is the same command with a version from the new line. The plan works out the target major version from `ovox_server_version`:

```bash
# OpenVox 8 to 9
bolt plan run ovadm::upgrade server_host=ovox-server.example.com ovox_server_version=9.0.0

# Puppet Server 7 to OpenVox 8
bolt plan run ovadm::upgrade server_host=puppet7.example.com ovox_server_version=8.16.0
```

Upgrade one major version at a time. A Puppet Server 7 host goes straight to OpenVox 8; OpenVox 7 is not needed in between. A Puppet Server 8 host moves to OpenVox 8 the same way.

For each node on an older major version, or still running Puppet Server, the plan does what the upstream upgrade guides describe by hand:

1. **Switches the package repository.** It installs the new major's release package (`openvox9-release`, say) and removes the release packages of other OpenVox and Puppet major versions. On Debian and Ubuntu the old one has to go first, since each ships the same apt preferences file. Nodes already on the target major keep their repository, so re-running the plan after a failure is safe.
2. **Installs the new package.** `openvox-server` replaces `puppetserver`, and the agent package on the node moves to the matching `openvox-agent`. The CA, certificates, `puppet.conf`, `conf.d`, and gems installed with `puppetserver gem` carry over. Replacing `puppetserver` makes the package's install hook reset the `[server]` paths in `puppet.conf` (`vardir`, `logdir`, `rundir`, `pidfile`, `codedir`); the plan puts your `puppet.conf` back afterwards.
3. **Makes sure the server has a supported Java.** OpenVox Server 8 runs `/usr/bin/java`, and its package pulls in a JRE but leaves the `java` alternative alone, so a Puppet Server 7 host still on Java 8 or 11 would fail at startup with `UnsupportedClassVersionError`. When the default Java is not 17 or 21, the plan points the `java` alternative at the newest of those installed. Precheck reports the old Java as a warning rather than a failure for this reason.
   OpenVox Server 9 packages (from 9.0.0-rc2) pick their own Java through a launcher, `/opt/puppetlabs/server/apps/puppetserver/bin/java`, that the service and the `puppetserver` CLI both run: the first of Java 25 and 21 installed, or `JAVA_BIN` from the defaults file when it names one of those. The `java` alternative doesn't reach the server there, so the plan leaves it alone and checks what the launcher runs instead. The launcher uses a `JAVA_BIN` as it is, whatever its version, so the plan stops before the restart if `JAVA_BIN` names a Java older than 21. Precheck follows the same rule: on a host that already has OpenVox Server 9 it checks the Java the launcher runs, and before an upgrade to 9 it does not check the system `java` at all.
4. **Restarts and waits for readiness**, as for any upgrade.

To upgrade to a new major version from a `package_url` alone, pass `ovox_major` as well, since there is no version to take it from.

### Order and what ovadm leaves to you

The plan upgrades the server, then the compilers. Upgrade agents only after that: an OpenVox 8 agent cannot use a Puppet 7 server, and fails with `Error 406 on SERVER: Not Acceptable` when the server falls back to PSON for a catalog. Older agents keep working against the upgraded server while you roll the new version out.

ovadm does not manage OpenVoxDB. Upgrade `openvoxdb` and `openvoxdb-termini` by hand, in the same maintenance window as the server, so the two do not run different major versions for longer than the upgrade takes.

Read the upstream guide for the upgrade first. Most of what changes between major versions is in the language, agents, and settings, which ovadm does not touch:

- [Upgrading from Puppet 7 to OpenVox 8](https://github.com/OpenVoxProject/openvox-docs/pull/498) (openvox-docs#498, in review)
- [Upgrading from OpenVox 8 to OpenVox 9](https://github.com/OpenVoxProject/openvox-docs/pull/461) (openvox-docs#461, in review)
