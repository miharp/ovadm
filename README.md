# ovadm — OpenVox Administration Module

ovadm is an [OpenBolt](https://github.com/OpenVoxProject/openbolt) module that automates the deployment, upgrade, and management of [OpenVox Server](https://docs.openvoxproject.org) infrastructure. It is modeled after [puppetlabs-peadm](https://github.com/puppetlabs/puppetlabs-peadm) and adapted for OpenVox's package-based install and simpler architecture (no console, orchestrator, or RBAC database).

> **Experimental.** This module works against real targets but has not been validated at scale.

## Requirements

- [OpenBolt](https://github.com/OpenVoxProject/openbolt) >= 5.0.0 (gem: `gem install openbolt`)
- Ruby >= 3.2 (for the test suite — use rbenv or equivalent, not the system Ruby)
- A supported Linux target: Rocky Linux 9, Ubuntu 22.04, Ubuntu 24.04, Debian 12 (tested in CI)
- Java 17 or 21 on the target — installed automatically as a dependency of `openvox-server`

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
catalogs. [codavox](https://github.com/miharp/codavox) fills that gap, and
`ovadm::codavox` sets it up end to end on an existing deployment: it installs the
package on the server and compilers, serves a seeded environment from the server,
converges each compiler's agent, then points OpenVox Server at codavox — in that
order, since a compiler wired before its agent has converged has nothing to serve.
It reuses the compiler certificates `add_compiler` already provisioned.

```bash
bolt plan run ovadm::codavox server_host=puppet compiler_hosts=compiler01,compiler02
```

It finishes by asking the publisher what every compiler reports serving, and
fails if they have not all converged on one `code_id` — so a compiler the
publisher refuses, or one whose agent never caught up, stops the plan rather than
being discovered later.

The publisher serves `basedir`, which is **r10k's `basedir`** — on a stock
install the codedir r10k already deploys into
(`/etc/puppetlabs/code/environments`). codavox needs no basedir area of its own.
If that environment has no manifests yet, the plan seeds a minimal one so the
publisher has something to serve; an environment that already has code is left
untouched.

## Quick start

```bash
bolt plan run ovadm::install server_host=ovox-server.example.com
```

Copy `inventory.yaml.example` to `inventory.yaml` and fill in your target details before running any plan.

## Documentation

- [Installing](documentation/install.md) — Standard, Large, DNS alt names, certificate auto-renewal, internal mirrors
- [Upgrading](documentation/upgrade.md) — Minor/patch and major version upgrades
- [Managing compilers](documentation/add_compiler.md) — Adding and removing compiler nodes
- [Architecture](documentation/architecture.md) — Topologies, plan structure, cert extensions, peadm comparison
- [Docker testing](documentation/docker_testing.md) — Local three-node dev environment
- [Implementation roadmap](documentation/plan.md) — Task catalog and design decisions

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for code style, testing, and PR guidance.

## Status

This project is experimental. It may move under the [OpenVox project](https://openvoxproject.org) organization if it gains community support.

## License

Apache-2.0 — see [LICENSE](LICENSE).
