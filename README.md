# ovadm — OpenVox Administration Module

ovadm is an [OpenBolt](https://github.com/OpenVoxProject/openbolt) module that automates the deployment, upgrade, and management of [OpenVox Server](https://docs.openvoxproject.org) infrastructure. It is modeled after [puppetlabs-peadm](https://github.com/puppetlabs/puppetlabs-peadm) and adapted for OpenVox's package-based install and simpler architecture (no console, orchestrator, or RBAC database).

> **Experimental.** This module works against real targets but has not been validated at scale. See [Open Questions](documentation/plan.md#open-questions) in the implementation plan.

## Supported topologies

### Standard

A single OpenVox Server node managing agents.

```text
[Agents] → [OpenVox Server]
```

### Large

A primary server plus one or more compile masters that distribute catalog compilation across large agent populations.

```text
[Agents] → [Load Balancer] → [Compiler Pool]
                                    ↓
                          [OpenVox Server (primary)]
```

## Plans

| Plan | Description |
| ---- | ----------- |
| `ovadm::install` | Install OpenVox Server (Standard or Large topology) |
| `ovadm::upgrade` | Upgrade an existing deployment in-place |
| `ovadm::status` | Report health: prechecks, service state, and installed version |
| `ovadm::add_compiler` | Add a compiler node to an existing deployment |

## Requirements

- [OpenBolt](https://github.com/OpenVoxProject/openbolt) >= 3.17.0 (gem: `openbolt`)
- Ruby >= 3.2 (for the test suite — use rbenv or equivalent, not the system Ruby)
- A supported Linux target: RHEL/Rocky/AlmaLinux 8–9, Debian 11–12, Ubuntu 22.04/24.04
- Java 17 or 21 on the target (validated by `ovadm::precheck`; installed as a dependency of `openvox-server`)

## Usage

### Install a Standard deployment

```bash
bolt plan run ovadm::install server_host=ovox.example.com
```

### Install a Large deployment

```bash
bolt plan run ovadm::install \
  server_host=ovox-primary.example.com \
  compiler_hosts=ovox-compiler01.example.com,ovox-compiler02.example.com
```

### Check deployment health

```bash
bolt plan run ovadm::status server_host=ovox.example.com
```

### Upgrade

```bash
bolt plan run ovadm::upgrade server_host=ovox.example.com ovox_version=8.4.0
```

### Add a compiler to an existing deployment

```bash
bolt plan run ovadm::add_compiler \
  server_host=ovox-primary.example.com \
  compiler_hosts=ovox-compiler03.example.com
```

### Quick status snapshot (no plan needed)

```bash
bolt task run ovadm::infrastatus --targets ovox.example.com
bolt task run ovadm::precheck    --targets ovox.example.com
```

## Inventory

Copy `inventory.yaml.example` to `inventory.yaml` and fill in your target details. This file is gitignored — do not commit real hostnames or credentials.

```bash
cp inventory.yaml.example inventory.yaml
```

## Architecture

Plans are thin orchestrators that delegate to focused subplans, which call atomic tasks. Every task outputs structured JSON so plans can branch on the results.

```text
ovadm::install
  └─ ovadm::subplans::precheck       (OS, Java, port, NTP validation)
  └─ ovadm::subplans::install        (configure_repo → install_server)
  └─ ovadm::subplans::configure      (puppet.conf)
  └─ ovadm::wait_until_service_ready
  └─ ovadm::subplans::agent_install  (compilers — Large topology only)
  └─ ovadm::subplans::cert_setup     (CSR submit → sign → agent run)
```

See [`documentation/plan.md`](documentation/plan.md) for the full task catalog and implementation roadmap.

## Key differences from peadm

| Concern | peadm (PE) | ovadm (OpenVox) |
| ------- | ---------- | --------------- |
| Installation | Tarball installer | OS packages via apt/yum |
| Java | Bundled | Required separately; validated by precheck |
| HA replica | Supported | Not supported (PE-only feature) |
| Console / RBAC | Required | Not present |
| Service name | `pe-puppetserver` | `puppetserver` |

## Development

### Running tests

```bash
# Install Ruby dependencies
bundle install

# Plan unit tests (BoltSpec mocks — no infrastructure required)
bundle exec rake unit

# Acceptance tests (requires a running Docker container named ovadm-acceptance)
docker run -d --name ovadm-acceptance rockylinux:9 sleep infinity
docker exec ovadm-acceptance bash -c "dnf install -y -q ca-certificates"
bundle exec rake acceptance
docker rm -f ovadm-acceptance
```

### Local Docker dev environment

`docker-compose.yml` defines a two-node environment (primary server + one compiler) using Rocky Linux 9 with systemd. This lets you run real Bolt plans against local containers.

```bash
# Build and start containers (systemd is active inside each container)
docker compose build
docker compose up -d

# Run a Standard install
bolt plan run ovadm::install server_host=puppet \
  --inventoryfile docker/inventory.yaml

# Add a compiler (Large topology)
bolt plan run ovadm::add_compiler \
  server_host=puppet compiler_hosts=compiler01 \
  --inventoryfile docker/inventory.yaml

# Check status
bolt plan run ovadm::status server_host=puppet \
  --inventoryfile docker/inventory.yaml

# Tear down
docker compose down
```

Port 8140 is forwarded to `localhost:8140` on the server container so you can query the API directly:

```bash
curl -k https://localhost:8140/status/v1/simple
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for code style and PR guidance.

## Status

This project is experimental. It may move under the [OpenVox project](https://openvoxproject.org) organization if it gains community support.

## License

Apache-2.0 — see [LICENSE](LICENSE).
