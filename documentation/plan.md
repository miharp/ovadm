# ovadm Implementation Plan

This document describes the planned functionality for ovadm, the OpenVox Administration Module. It is a living document — update it as decisions are made and research fills gaps.

Modeled after [puppetlabs-peadm](https://github.com/puppetlabs/puppetlabs-peadm), ovadm provides Bolt plans and tasks that automate the deployment, upgrade, and lifecycle management of OpenVox Server infrastructure.

---

## Supported Topologies

OpenVox Server does not support HA replicas (that is a Puppet Enterprise feature). ovadm supports two topologies:

### Standard

A single OpenVox Server node managing agents.

```text
[Agents] → [OpenVox Server]
```

### Large

A server plus one or more compilers to distribute compilation load across large agent populations.

```text
[Agents] → [Load Balancer] → [Compiler Pool]
                                    ↓
                          [OpenVox Server]
```

---

## Plans

### Top-Level Plans

| Plan | Description | Priority |
|------|-------------|----------|
| `ovadm::install` | Install a new OpenVox Server deployment | P0 |
| `ovadm::upgrade` | Upgrade an existing deployment in-place | P0 |
| `ovadm::status` | Report health of a running deployment | P0 |
| `ovadm::add_compiler` | Add a node to the `compiler_hosts` pool | P1 |

### Subplans (internal)

The top-level plans should be thin orchestrators that call focused subplans. This mirrors peadm's structure and makes individual steps testable.

**Install subplans:**

| Plan | Description |
|------|-------------|
| `ovadm::subplans::precheck` | Validate targets, OS, Java, ports, time sync |
| `ovadm::subplans::install` | Install packages and start services on the server |
| `ovadm::subplans::configure` | Apply initial configuration (puppet.conf) |
| `ovadm::subplans::agent_install` | Install OpenVox server on `compiler_hosts` targets and configure puppet.conf |
| `ovadm::subplans::cert_setup` | Submit and sign CSRs; embed pp_role extension |

**Upgrade subplans:**

| Plan | Description |
|------|-------------|
| `ovadm::subplans::upgrade_server` | Upgrade the server |
| `ovadm::subplans::upgrade_compilers` | Upgrade compiler pool nodes |

---

## Task Catalog

Tasks are the atomic operations that plans compose. The following are implemented, grouped by function:

### Platform & Preflight

| Task | Description | Notes |
|------|-------------|-------|
| `ovadm::precheck` | Validate OS, Java version, open ports, NTP sync | Returns structured JSON |
| `ovadm::os_identification` | Detect OS family, version, arch | Used to select package repo |
| `ovadm::wait_until_service_ready` | Poll until `puppetserver` responds on :8140 | Avoids race conditions after start |

### Package & Repository Management

| Task | Description | Notes |
|------|-------------|-------|
| `ovadm::configure_repo` | Enable the appropriate OpenVox apt/yum repo | Supports `apt_base_url`/`yum_base_url` for internal mirrors |
| `ovadm::install_server` | Install `openvox-server` package | Triggers systemd service setup |
| `ovadm::install_agent` | Install `openvox-agent` package | For compilers |
| `ovadm::get_version` | Return installed OpenVox Server version | Used in upgrade validation |

### Service Management

| Task | Description | Notes |
|------|-------------|-------|
| `ovadm::service_status` | Report status of `puppetserver` service | Returns structured JSON |
| `ovadm::service_start` | Start `puppetserver` | |
| `ovadm::service_stop` | Stop `puppetserver` | |
| `ovadm::service_restart` | Restart `puppetserver` | Used post-config-change |

### Certificate Authority

| Task | Description | Notes |
|------|-------------|-------|
| `ovadm::set_csr_attributes` | Write `csr_attributes.yaml` with `pp_role` extension | Must run before first agent run or puppetserver start |
| `ovadm::sign_csr` | Sign a pending CSR on the CA; handles already-signed gracefully | |

### Configuration Management

| Task | Description | Notes |
|------|-------------|-------|
| `ovadm::configure_puppet_conf` | Write `puppet.conf` on a target | Supports `ca_server` for compiler configuration |
| `ovadm::configure_compiler_ssl` | Configure SSL directories for compiler-mode operation | Run after cert signing |

### Agent Operations

| Task | Description | Notes |
|------|-------------|-------|
| `ovadm::agent_runonce` | Run the agent once on a target | Used for CSR submission and initial catalog application |

### Status & Introspection

| Task | Description | Notes |
|------|-------------|-------|
| `ovadm::infrastatus` | Return full deployment status as JSON | Summary view for operators |

---

## Implementation Phases

### Phase 1 — Foundation (do first)

Goal: enough scaffolding to run against a real target and get meaningful output.

- [x] `ovadm::precheck` task — validates OS family, Java, port 8140, NTP
- [x] `ovadm::os_identification` task
- [x] `ovadm::service_status` task — returns structured JSON
- [x] `ovadm::status` plan — calls precheck + service_status and returns a report
- [x] `ovadm::subplans::precheck` plan — wraps the task with clear failure messages
- [x] Bolt inventory example (`inventory.yaml.example`)
- [x] Basic spec tests for tasks (10 acceptance tests, all passing)

**Deliverable:** `bolt plan run ovadm::status server_host=<target>` returns a real health report.

### Phase 2 — Install (Standard topology)

Goal: fully automated install of OpenVox Server on a single node.

- [x] `ovadm::configure_repo` task (apt + yum/dnf)
- [x] `ovadm::install_server` task
- [x] `ovadm::wait_until_service_ready` task
- [x] `ovadm::configure_puppet_conf` task
- [x] `ovadm::subplans::install` plan
- [x] `ovadm::subplans::configure` plan
- [x] `ovadm::install` plan (top-level, standard topology only)

Scope notes:

- `java_check` task dropped — `ovadm::precheck` already validates Java, and apt/yum pulls it in as a dependency of `openvox-server`.
- `sign_csr` / `submit_csr` deferred to Phase 5 — not needed for a standard single-node install where the server is its own CA.

**Deliverable:** `bolt plan run ovadm::install server_host=<target>` installs and configures a working OpenVox Server.

### Phase 3 — Status & Introspection

Goal: enrich status reporting and provide a single-task status dump for monitoring.

- [x] `ovadm::get_version` task — returns installed `openvox-server` version or `not_installed`
- [x] `ovadm::infrastatus` task — concise JSON status: version, service state, port 8140
- [x] `ovadm::status` plan — extended to include version in the report

Scope notes:

- `get_config` / `write_config` / `ovadm::convert` dropped — OpenVox has no console, RBAC, or orchestrator to wire up, so "adopting" an existing server into ovadm is just `ovadm::status` against it. No config file adoption needed.

**Deliverable:** `bolt plan run ovadm::status server_host=<target>` reports version alongside precheck and service status. `bolt task run ovadm::infrastatus --targets <target>` gives a quick machine-readable snapshot.

### Phase 4 — Upgrade

Goal: in-place version upgrade with service continuity.

- [x] `ovadm::get_version` task (finalized in Phase 3)
- [x] `ovadm::service_stop` / `ovadm::service_start` / `ovadm::service_restart`
- [x] `ovadm::subplans::upgrade_server` plan
- [x] `ovadm::upgrade` plan (standard topology)

**Deliverable:** `bolt plan run ovadm::upgrade server_host=<target> ovox_version=8.x.x` upgrades cleanly.

### Phase 5 — Large Topology (Compiler Pool)

Goal: install and upgrade across `server_host` + `compiler_hosts` deployments.

- [x] `ovadm::install_agent` task
- [x] `ovadm::agent_runonce` task
- [x] `ovadm::sign_csr` task — handles already-signed certs gracefully (autosign-safe)
- [x] `ovadm::set_csr_attributes` task — embeds `pp_role` in the CSR via `csr_attributes.yaml`
- [x] `ovadm::configure_compiler_ssl` task — configures SSL for compiler-mode operation
- [x] `configure_puppet_conf` extended with `ca_server` parameter
- [x] `ovadm::subplans::agent_install` plan
- [x] `ovadm::subplans::cert_setup` plan — sets `pp_role: openvox_compiler`, submits CSR, signs, runs agent
- [x] `ovadm::add_compiler` plan
- [x] Extend `ovadm::install` for Large topology
- [x] `ovadm::subplans::upgrade_compilers`
- [x] Extend `ovadm::upgrade` for Large topology

### Phase 6 — Internal Mirror Support

Goal: support air-gapped or proxied package repositories.

- [x] `configure_repo` extended with optional `apt_base_url` / `yum_base_url` parameters
- [x] `apt_base_url` / `yum_base_url` threaded through `install`, `upgrade`, and `add_compiler` top-level plans

**Deliverable:** All plans accept optional mirror URL parameters; omitting them defaults to public VoxPupuli repos.

---

## Key Differences from peadm

These are the places where ovadm diverges from peadm by necessity:

### Installation method

peadm downloads and runs a PE installer tarball. OpenVox is installed via OS packages:

```bash
# apt
wget https://apt.voxpupuli.org/openvox8-release-ubuntu22.04.deb
dpkg -i openvox8-release-ubuntu22.04.deb
apt install openvox-server

# yum/dnf
rpm -Uvh https://yum.voxpupuli.org/openvox8-release-el-9.noarch.rpm
yum install openvox-server
```

The `ovadm::configure_repo` and `ovadm::install_server` tasks replace peadm's `download` + `pe_install` pattern entirely.

### Java dependency

OpenVox Server requires Java 17 or Java 21 to be available on the target before installation. This is a mandatory precheck step that has no equivalent in peadm.

### Service names

| Component | peadm | ovadm |
|-----------|-------|-------|
| Server process | `pe-puppetserver` | `puppetserver` |
| CA service | embedded in `pe-puppetserver` | embedded in `puppetserver` |
| Database | `pe-postgresql` | External PostgreSQL or bundled |

### No console, no orchestrator

PE has a web console, activity service, RBAC database, and orchestrator service. OpenVox has none of these. The configure subplan is significantly simpler: there is no PE Console node group classification to manage.

### No RBAC / token API

peadm generates RBAC tokens for API access. OpenVox uses standard SSL client certificate auth. The `rbac_token` and `validate_rbac_token` tasks are not needed.

### Configuration file paths

| File | peadm (PE) | ovadm (OpenVox) |
|------|-----------|-----------------|
| Main config | `/etc/puppetlabs/puppet/puppet.conf` | `/etc/puppetlabs/puppet/puppet.conf` |
| Server config dir | `/etc/puppetlabs/puppetserver/conf.d/` | `/etc/puppetlabs/puppetserver/conf.d/` |
| Auth rules | `/etc/puppetlabs/puppetserver/conf.d/auth.conf` | `/etc/puppetlabs/puppetserver/conf.d/auth.conf` |
| SSL dir | `/etc/puppetlabs/puppet/ssl/` | `/etc/puppetlabs/puppet/ssl/` |
| CA cert | `/etc/puppetlabs/puppetserver/ca/ca_crt.pem` | `/etc/puppetlabs/puppetserver/ca/ca_crt.pem` |

**Confirmed on OpenVox 8.13.0 / CentOS Stream 10.** OpenVox inherits the `/etc/puppetlabs/` layout from upstream Puppet — it does not install under `/etc/openvox/` (that directory contains only `openvox.yml`, the OpenVox-specific service config).

### Certificate role extensions

peadm uses a custom OID arc for node role classification. ovadm uses the standard Puppet registered `pp_role` OID via `csr_attributes.yaml`, written before the node's first agent run (or before puppetserver's first start on the primary). The signed cert carries `$trusted['extensions']['pp_role']` for classification in Puppet code without a node classifier.

| Node type | `pp_role` value |
|-----------|-----------------|
| OpenVox Server | `openvox_server` |
| Compiler | `openvox_compiler` |

### Code management

peadm has deep Code Manager / r10k integration. OpenVox uses standard Puppet code deployment (r10k or direct). ovadm should support r10k configuration optionally but not require it for a basic install.

---

## Open Questions

1. ~~**Exact config file paths**~~ — Confirmed on OpenVox 8.13.0 / CentOS Stream 10. OpenVox inherits the `/etc/puppetlabs/` layout from upstream Puppet: `puppet.conf` at `/etc/puppetlabs/puppet/puppet.conf`, conf.d at `/etc/puppetlabs/puppetserver/conf.d/`, SSL at `/etc/puppetlabs/puppet/ssl/`. The `/etc/openvox/` directory exists but contains only `openvox.yml` (OpenVox-specific service config).

2. ~~**Service name**~~ — Confirmed `puppetserver` via [install_from_packages](https://docs.openvoxproject.org/openvox-server/latest/install_from_packages.html)

3. ~~**PostgreSQL packaging**~~ — Confirmed: OpenVox does not bundle PostgreSQL. The operator provides it from OS packages (EL10 AppStream ships PostgreSQL 16). OpenVoxDB (`openvoxdb`, `openvoxdb-termini` packages) integrates with whatever PostgreSQL is present.

4. ~~**OpenVoxDB**~~ — Confirmed: package names are `openvoxdb` and `openvoxdb-termini`; service name is `puppetdb`. Not required for a basic install — OpenVox Server serves catalogs and acts as its own CA without it. Required if `storeconfigs`/reports are enabled.

5. ~~**Certificate extensions / compiler roles**~~ — Confirmed: OpenVox supports `csr_attributes.yaml` and the standard Puppet `pp_role` registered OID identically to upstream Puppet. ovadm uses `ovadm::set_csr_attributes` to write `extension_requests: pp_role: openvox_compiler` on compiler nodes before their first agent run (and `openvox_server` on the primary before first puppetserver start); the signed cert then carries `$trusted['extensions']['pp_role']` for classification in Puppet code. (peadm uses a custom OID arc; ovadm prefers the standard registered extension.)

6. ~~**Supported OS matrix**~~ — Targeting modern LTS platforms only: Rocky Linux 9, Ubuntu 22.04, Ubuntu 24.04, Debian 12. OpenVox publishes packages for a much wider set (EL 8-10, Debian 11-13, Ubuntu 20.04-26.04, Amazon Linux, SLES, Fedora) and other platforms will likely work, but CI coverage is intentionally kept narrow to reduce build burden.

7. ~~**Minimum Bolt version**~~ — Confirmed: targeting OpenBolt >= 5.0.0 (current series is 5.x). `metadata.json` updated. The 3.17.0 floor inherited from peadm was discarded.

---

## Contributing

If you are picking up a task, please open an issue first so work is not duplicated. See [CONTRIBUTING.md](../CONTRIBUTING.md) for code style and PR guidance.
