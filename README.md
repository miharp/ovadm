# ovadm - OpenVox Administration Module

[![CI](https://github.com/miharp/ovadm/actions/workflows/ci.yml/badge.svg)](https://github.com/miharp/ovadm/actions/workflows/ci.yml)
[![Install test](https://github.com/miharp/ovadm/actions/workflows/install-test.yml/badge.svg)](https://github.com/miharp/ovadm/actions/workflows/install-test.yml)
[![Release](https://img.shields.io/github/v/release/miharp/ovadm)](https://github.com/miharp/ovadm/releases/latest)
[![Puppet Forge](https://img.shields.io/puppetforge/v/miharp/ovadm)](https://forge.puppet.com/modules/miharp/ovadm)
[![License](https://img.shields.io/github/license/miharp/ovadm)](https://github.com/miharp/ovadm/blob/main/LICENSE)

ovadm is an [OpenBolt](https://github.com/OpenVoxProject/openbolt) module for deploying, upgrading, and managing [OpenVox Server](https://docs.openvoxproject.org) infrastructure. It is modeled after [puppetlabs-peadm](https://github.com/puppetlabs/puppetlabs-peadm) and adapted for OpenVox's package-based install and simpler architecture (no console, orchestrator, or RBAC database).

> **Experimental.** This module works against real targets but has not been validated at scale.

## Requirements

- [OpenBolt](https://github.com/OpenVoxProject/openbolt) >= 5.0.0 (gem: `gem install openbolt`)
- Ruby >= 3.2 (for the test suite - use rbenv or equivalent, not the system Ruby)
- A supported Linux target: Rocky Linux 9, Ubuntu 22.04, Ubuntu 24.04, Debian 12 (tested in CI); AlmaLinux 9 and 10 (tested by hand on cloud VMs)
- Java 17 or 21 on the target - installed automatically as a dependency of `openvox-server`

## Plans

| Plan | Description |
| ---- | ----------- |
| `ovadm::install` | Install OpenVox Server (Standard or Large topology) |
| `ovadm::upgrade` | Upgrade an existing deployment in-place |
| `ovadm::status` | Report health: prechecks, service state, and installed version |
| `ovadm::add_compiler` | Add a compiler node to an existing deployment |

## Installing

Pin a release in your `Puppetfile`, from the [Forge](https://forge.puppet.com/modules/miharp/ovadm):

```ruby
mod 'miharp-ovadm', '0.4.0'
```

or straight from git, which is the same code under the same version:

```ruby
mod 'miharp-ovadm',
  git: 'https://github.com/miharp/ovadm',
  tag: 'v0.4.0'
```

Releases are listed on the [releases page](https://github.com/miharp/ovadm/releases), with notes in [CHANGELOG.md](https://github.com/miharp/ovadm/blob/main/CHANGELOG.md). Running from a clone works too — every plan below is run with `--modulepath` pointed at the checkout's parent, or from inside a Bolt project that has it on the modulepath.

## Quick start

```bash
bolt plan run ovadm::install server_host=ovox-server.example.com
```

Copy `inventory.yaml.example` to `inventory.yaml` and fill in your target details before running any plan.

## Documentation

- [Installing](https://github.com/miharp/ovadm/blob/main/documentation/install.md) - Standard, Large, DNS alt names, certificate auto-renewal, internal mirrors
- [Upgrading](https://github.com/miharp/ovadm/blob/main/documentation/upgrade.md) - Minor/patch and major version upgrades
- [Managing compilers](https://github.com/miharp/ovadm/blob/main/documentation/add_compiler.md) - Adding and removing compiler nodes
- [Architecture](https://github.com/miharp/ovadm/blob/main/documentation/architecture.md) - Topologies, plan structure, cert extensions, peadm comparison
- [Docker testing](https://github.com/miharp/ovadm/blob/main/documentation/docker_testing.md) - Local three-node dev environment
- [Implementation roadmap](https://github.com/miharp/ovadm/blob/main/documentation/plan.md) - Task catalog and design decisions

## Contributing

See [CONTRIBUTING.md](https://github.com/miharp/ovadm/blob/main/CONTRIBUTING.md) for code style, testing, and PR guidance.

## Status

This project is experimental. It may move under the [OpenVox project](https://openvoxproject.org) organization if it gains community support.

## License

Apache-2.0 - see [LICENSE](https://github.com/miharp/ovadm/blob/main/LICENSE).
