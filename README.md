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

- [OpenBolt](https://github.com/OpenVoxProject/openbolt) (gem: `openbolt`)
- Ruby >= 3.2 (for the test suite — use rbenv or equivalent, not the system Ruby)
- A supported Linux target: Rocky Linux 9, Ubuntu 22.04 (tested in CI); other RHEL-family and Debian-family platforms should work
- Java 17 or 21 on the target — installed automatically as a dependency of `openvox-server`; `ovadm::precheck` warns if absent but does not block the install

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
  └─ systemctl enable --now puppetserver
  └─ ovadm::wait_until_service_ready
  └─ ovadm::subplans::agent_install  (compilers — Large topology only)
  └─ ovadm::subplans::cert_setup     (CSR submit → sign → agent run)
```

See [`documentation/plan.md`](documentation/plan.md) for the full task catalog and implementation roadmap.

## Key differences from peadm

| Concern | peadm (PE) | ovadm (OpenVox) |
| ------- | ---------- | --------------- |
| Installation | Tarball installer | OS packages via apt/yum |
| Java | Bundled | Installed as a package dependency; precheck warns if absent |
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

`docker-compose.yml` defines a three-node environment using Rocky Linux 9 with systemd:

| Container | Role | Image |
| --------- | ---- | ----- |
| `ovadm-server` | Primary OpenVox Server (CA) | Built from `docker/Dockerfile` |
| `ovadm-compiler01` | Compiler | Built from `docker/Dockerfile` |
| `ovadm-agent` | Agent (catalog verification) | `ghcr.io/openvoxproject/openvoxagent:latest` |

The agent is pre-configured (via `docker/agent-puppet.conf`) to request catalogs from `compiler01` and certificates from the primary server.

```bash
# Build and start all three containers
docker compose build
docker compose up -d

# 1. Install the primary OpenVox Server
bolt plan run ovadm::install server_host=puppet \
  --inventoryfile docker/inventory.yaml

# 2. Enable autosign so the agent cert is signed automatically
#    (bolt's docker transport doesn't shell-expand redirects; use docker exec directly)
docker exec ovadm-server bash -c 'echo "*" > /etc/puppetlabs/puppet/autosign.conf'

# 3. Add the compiler (Large topology)
bolt plan run ovadm::add_compiler \
  server_host=puppet compiler_hosts=compiler01 \
  --inventoryfile docker/inventory.yaml

# 4. Run the agent — connects to compiler01 for catalog compilation,
#    cert is autosigned by the primary server
docker exec ovadm-agent /opt/puppetlabs/bin/puppet agent -t

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
