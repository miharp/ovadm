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

## Quick start

```bash
bolt plan run ovadm::install server_host=ovox-server.example.com
```

Copy `inventory.yaml.example` to `inventory.yaml` and fill in your target details before running any plan.

## Documentation

- [Installing](documentation/install.md) — Standard, Large, DNS alt names, internal mirrors
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
