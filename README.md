# ovadm — OpenVox Administration Module

> **Experimental.** This module is in early development. Plans are currently stubs — contributions welcome.

ovadm is a [Bolt](https://www.puppet.com/docs/bolt/latest/bolt.html) module that automates the deployment, upgrade, and management of [OpenVox Server](https://docs.openvoxproject.org) infrastructure. It is modeled after [puppetlabs-peadm](https://github.com/puppetlabs/puppetlabs-peadm) and aims to bring the same operational rigor to the OpenVox ecosystem.

## What it does (planned)

| Plan | Description |
|------|-------------|
| `ovadm::install` | Install a new OpenVox Server |
| `ovadm::upgrade` | Upgrade an existing OpenVox Server deployment |
| `ovadm::status` | Check the health of a running OpenVox Server |

## Requirements

- [Bolt](https://www.puppet.com/docs/bolt/latest/bolt_installing.html) >= 3.17.0
- A supported Linux target (RHEL 8/9, Debian 11/12, Ubuntu 22.04/24.04)

## Usage

```
# Check status of your OpenVox Server
bolt plan run ovadm::status server_host=ovox.example.com
```

Full parameter documentation for each plan is in the [`documentation/`](documentation/) directory.

## Status

This project is **experimental**. It may move under the [OpenVox project](https://openvoxproject.org) organization if it gains community support.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). The most impactful contribution right now is implementing the install and upgrade plans.

## License

Apache-2.0 — see [LICENSE](LICENSE).
