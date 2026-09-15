# Changelog

Notable changes to ovadm are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) — while ovadm is in
0.x, a minor version may carry breaking changes.

## [Unreleased]

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

[Unreleased]: https://github.com/miharp/ovadm/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/miharp/ovadm/releases/tag/v0.2.0
