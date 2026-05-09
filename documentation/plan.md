# ovadm Implementation Plan

This document describes the planned functionality for ovadm, the OpenVox Administration Module. It is a living document — update it as decisions are made and research fills gaps.

Modeled after [puppetlabs-peadm](https://github.com/puppetlabs/puppetlabs-peadm), ovadm provides Bolt plans and tasks that automate the deployment, upgrade, and lifecycle management of OpenVox Server infrastructure.

---

## Supported Topologies

OpenVox Server does not support HA replicas (that is a Puppet Enterprise feature). ovadm supports two topologies:

### Standard
A single OpenVox Server node managing agents.

```
[Agents] → [OpenVox Server]
```

### Large
A server plus one or more compilers to distribute compilation load across large agent populations.

```
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
| `ovadm::convert` | Take over management of an existing unmanaged OpenVox Server | P1 |
| `ovadm::add_compiler` | Add a node to the `compiler_hosts` pool | P1 |

### Subplans (internal)

The top-level plans should be thin orchestrators that call focused subplans. This mirrors peadm's structure and makes individual steps testable.

**Install subplans:**

| Plan | Description |
|------|-------------|
| `ovadm::subplans::precheck` | Validate targets, OS, Java, ports, time sync |
| `ovadm::subplans::install` | Install packages and start services on the server |
| `ovadm::subplans::configure` | Apply initial configuration (puppet.conf, auth.conf) |
| `ovadm::subplans::agent_install` | Install OpenVox agent on `compiler_hosts` targets |
| `ovadm::subplans::cert_setup` | Submit and sign CSRs; configure DNS alt names |

**Upgrade subplans:**

| Plan                                 | Description                 |
|--------------------------------------|-----------------------------|
| `ovadm::subplans::upgrade_server`    | Upgrade the server          |
| `ovadm::subplans::upgrade_compilers` | Upgrade compiler pool nodes |

---

## Task Catalog

Tasks are the atomic operations that plans compose. The following are needed, grouped by function:

### Platform & Preflight

| Task | Description | Notes |
|------|-------------|-------|
| `ovadm::precheck` | Validate OS, Java version, open ports, NTP sync | Return structured JSON |
| `ovadm::os_identification` | Detect OS family, version, arch | Used to select package repo |
| `ovadm::java_check` | Verify Java 17 or 21 is available | OpenVox-specific requirement |
| `ovadm::wait_until_service_ready` | Poll until `puppetserver` responds on :8140 | Avoid race conditions after start |

### Package & Repository Management

| Task | Description | Notes |
|------|-------------|-------|
| `ovadm::configure_repo` | Enable the appropriate OpenVox apt/yum repo | Distinct from peadm (no tarball) |
| `ovadm::install_server` | Install `openvox-server` package | Triggers systemd service setup |
| `ovadm::install_agent` | Install `openvox-agent` package | For compilers |
| `ovadm::uninstall_server` | Remove OpenVox Server packages | Used for reinstall/cleanup |
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
| `ovadm::submit_csr` | Submit a CSR from a target agent | |
| `ovadm::sign_csr` | Sign pending CSRs on the CA (server) | |
| `ovadm::cert_data` | Return certificate metadata for a node | |
| `ovadm::cert_valid_status` | Check if a cert is valid, expired, or missing | |
| `ovadm::ssl_clean` | Clean SSL state for a node (regenerate cert) | Needed for convert and rebuild |
| `ovadm::modify_certificate` | Add/modify extensions on a certificate | For availability group OIDs |

### Configuration Management

| Task | Description | Notes |
|------|-------------|-------|
| `ovadm::mkdir_p_file` | Create directories and write files | Multipurpose; used throughout |
| `ovadm::read_file` | Return contents of a file | Useful for config inspection |
| `ovadm::configure_puppet_conf` | Write `puppet.conf` on a target | Templated |
| `ovadm::configure_auth_conf` | Write `auth.conf` on the server | For API access control |

### Agent Operations

| Task | Description | Notes |
|------|-------------|-------|
| `ovadm::agent_runonce` | Run the agent once on a target | Used throughout orchestration |
| `ovadm::agent_enable` | Enable the agent service | Set final agent state |
| `ovadm::agent_disable` | Disable the agent service | |

### Status & Introspection

| Task | Description | Notes |
|------|-------------|-------|
| `ovadm::infrastatus` | Return full deployment status as JSON | Summary view for operators |
| `ovadm::get_config` | Return current ovadm-managed configuration | Stored in a known location on the server |

### Utility

| Task | Description | Notes |
|------|-------------|-------|
| `ovadm::filesize` | Return file size | Useful for download verification |
| `ovadm::download` | Download a file via curl/wget | May be needed for Java or supplemental packages |

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

- [ ] `ovadm::get_version` task (finalize)
- [ ] `ovadm::service_stop` / `ovadm::service_start` / `ovadm::service_restart`
- [ ] `ovadm::subplans::upgrade_server` plan
- [ ] `ovadm::upgrade` plan (standard topology)

**Deliverable:** `bolt plan run ovadm::upgrade server_host=<target> ovox_version=8.x.x` upgrades cleanly.

### Phase 5 — Large Topology (Compiler Pool)

Goal: install and upgrade across `server_host` + `compiler_hosts` deployments.

- [ ] `ovadm::install_agent` task
- [ ] `ovadm::agent_runonce` task
- [ ] `ovadm::modify_certificate` task (compiler role OIDs)
- [ ] `ovadm::add_compiler` plan
- [ ] Extend `ovadm::install` for Large topology
- [ ] `ovadm::subplans::upgrade_compilers`
- [ ] Extend `ovadm::upgrade` for Large topology

**Deliverable:** `bolt plan run ovadm::install server_host=<target> compiler_hosts=<c1>,<c2>` installs a working Large topology.

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
| Main config | `/etc/puppetlabs/puppet/puppet.conf` | `/etc/openvox/puppet.conf` |
| Server config dir | `/etc/puppetlabs/puppetserver/conf.d/` | `/etc/puppetserver/conf.d/` |
| Auth rules | `/etc/puppetlabs/puppetserver/conf.d/auth.conf` | `/etc/puppetserver/conf.d/auth.conf` |

**Note:** Confirm these paths against the running system — OpenVox docs are still being written and paths should be treated as provisional until verified on a real install.

### Code management

peadm has deep Code Manager / r10k integration. OpenVox uses standard Puppet code deployment (r10k or direct). ovadm should support r10k configuration optionally but not require it for a basic install.

---

## Open Questions

These need research or community input before implementation:

1. **Exact config file paths** — What are the canonical paths for `puppet.conf`, `puppetserver.conf`, and `auth.conf` on a fresh OpenVox 8 install? Needs verification on a real system.

2. ~~**Service name**~~ — Confirmed `puppetserver` via [install_from_packages](https://docs.openvoxproject.org/openvox-server/latest/install_from_packages.html)

3. **PostgreSQL packaging** — Does OpenVox ship a bundled PostgreSQL, or does the operator provide their own? What is the recommended version?

4. **OpenVoxDB** — Is it required for any ovadm functionality, or always optional? What are its package names?

5. **Certificate extensions / compiler roles** — Does OpenVox support OID-based role tagging on certificates (as peadm uses for compiler classification), or does this need a different approach?

6. **Supported OS matrix** — Should ovadm target the full OpenVox compatibility list (EL 7-10, Debian 10-13, Ubuntu 18.04-26.04) or a narrower set initially?

7. **Minimum Bolt version** — 3.17.0 is inherited from peadm. Confirm this is compatible with the plan features we intend to use.

---

## Contributing

If you are picking up a task from Phase 1 or 2, please open an issue first so work is not duplicated. See [CONTRIBUTING.md](../CONTRIBUTING.md) for code style and PR guidance.
