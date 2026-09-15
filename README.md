# ovadm - OpenVox Administration Module

[![CI](https://github.com/miharp/ovadm/actions/workflows/ci.yml/badge.svg)](https://github.com/miharp/ovadm/actions/workflows/ci.yml)
[![Install test](https://github.com/miharp/ovadm/actions/workflows/install-test.yml/badge.svg)](https://github.com/miharp/ovadm/actions/workflows/install-test.yml)
[![Release](https://img.shields.io/github/v/release/miharp/ovadm)](https://github.com/miharp/ovadm/releases/latest)
[![License](https://img.shields.io/github/license/miharp/ovadm)](LICENSE)

ovadm is an [OpenBolt](https://github.com/OpenVoxProject/openbolt) module for deploying, upgrading, and managing [OpenVox Server](https://docs.openvoxproject.org) infrastructure. It is modeled after [puppetlabs-peadm](https://github.com/puppetlabs/puppetlabs-peadm) and adapted for OpenVox's package-based install and simpler architecture (no console, orchestrator, or RBAC database).

> **Experimental.** This module works against real targets but has not been validated at scale.

## Requirements

- [OpenBolt](https://github.com/OpenVoxProject/openbolt) >= 5.0.0 (gem: `gem install openbolt`)
- Ruby >= 3.2 (for the test suite - use rbenv or equivalent, not the system Ruby)
- A supported Linux target: Rocky Linux 9, Ubuntu 22.04, Ubuntu 24.04, Debian 12 (tested in CI)
- Java 17 or 21 on the target - installed automatically as a dependency of `openvox-server`

## Plans

| Plan | Description |
| ---- | ----------- |
| `ovadm::install` | Install OpenVox Server (Standard or Large topology) |
| `ovadm::upgrade` | Upgrade an existing deployment in-place |
| `ovadm::status` | Report health: prechecks, service state, and installed version |
| `ovadm::add_compiler` | Add a compiler node to an existing deployment |
| `ovadm::codavox` | Install and wire [codavox](https://github.com/miharp/codavox) for versioned code distribution |

### Distributing code with codavox

OpenVox Server ships without Puppet Enterprise's Code Manager and file sync, so
there is no built-in way to get resolved code onto compilers or to serve static
catalogs. [codavox](https://github.com/miharp/codavox) provides both, and
`ovadm::codavox` sets it up end to end on an existing deployment: it installs the
package on the server and compilers, serves a seeded environment from the server,
converges each compiler's agent, then points OpenVox Server at codavox - in that
order, since a compiler wired before its agent has converged has nothing to serve.
It reuses the compiler certificates `add_compiler` already provisioned.

```bash
bolt plan run ovadm::codavox server_host=puppet compiler_hosts=compiler01,compiler02
```

The package comes from the [harpworks repository](https://packages.harpworks.org),
which the plan configures on every node with its signing key pinned in the task,
so `codavox_version` is a plain version and upgrades are the package manager's.
A `package_url` installs a file or URL instead, for a snapshot of unreleased
code. On each compiler the plan also allows codavox's agent to expire the
server's environment cache, which codavox 0.7 and later require.

It finishes by asking the publisher what every compiler reports serving, and
fails if they have not all converged on one `code_id` - so a compiler the
publisher refuses, or one whose agent never caught up, stops the plan rather than
being discovered later.

The publisher serves `basedir`, which is **r10k's `basedir`** - on a stock
install the codedir r10k already deploys into
(`/etc/puppetlabs/code/environments`). codavox needs no basedir area of its own.
If that environment has no manifests yet, the plan seeds a minimal one so the
publisher has something to serve; an environment that already has code is left
untouched.

## Installing

Pin a release in your `Puppetfile`:

```ruby
mod 'miharp-ovadm',
  git: 'https://github.com/miharp/ovadm',
  tag: 'v0.2.0'
```

Releases are listed on the [releases page](https://github.com/miharp/ovadm/releases), with notes in [CHANGELOG.md](CHANGELOG.md). ovadm is not published to the Forge. Running from a clone works too — every plan below is run with `--modulepath` pointed at the checkout's parent, or from inside a Bolt project that has it on the modulepath.

## Quick start

```bash
bolt plan run ovadm::install server_host=ovox-server.example.com
```

Copy `inventory.yaml.example` to `inventory.yaml` and fill in your target details before running any plan.

## Documentation

- [Installing](documentation/install.md) - Standard, Large, DNS alt names, certificate auto-renewal, internal mirrors
- [Upgrading](documentation/upgrade.md) - Minor/patch and major version upgrades
- [Managing compilers](documentation/add_compiler.md) - Adding and removing compiler nodes
- [Architecture](documentation/architecture.md) - Topologies, plan structure, cert extensions, peadm comparison
- [Docker testing](documentation/docker_testing.md) - Local three-node dev environment
- [Implementation roadmap](documentation/plan.md) - Task catalog and design decisions

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for code style, testing, and PR guidance.

## Status

This project is experimental. It may move under the [OpenVox project](https://openvoxproject.org) organization if it gains community support.

## License

Apache-2.0 - see [LICENSE](LICENSE).
