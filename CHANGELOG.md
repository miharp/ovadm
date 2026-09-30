# Changelog

Notable changes to ovadm are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) — while ovadm is in
0.x, a minor version may carry breaking changes.

## [Unreleased]

### Added

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

[Unreleased]: https://github.com/miharp/ovadm/compare/v0.4.1...HEAD
[0.4.1]: https://github.com/miharp/ovadm/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/miharp/ovadm/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/miharp/ovadm/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/miharp/ovadm/releases/tag/v0.2.0
