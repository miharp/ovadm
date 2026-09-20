# Changelog

Notable changes to ovadm are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) — while ovadm is in
0.x, a minor version may carry breaking changes.

## [Unreleased]

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

[Unreleased]: https://github.com/miharp/ovadm/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/miharp/ovadm/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/miharp/ovadm/releases/tag/v0.2.0
