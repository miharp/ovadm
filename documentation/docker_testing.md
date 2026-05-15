# Local Docker testing

`docker-compose.yml` defines a three-node environment using Rocky Linux 9 with systemd for end-to-end testing without real infrastructure.

## Containers

| Container | Role | Image |
| --------- | ---- | ----- |
| `ovadm-server` | OpenVox Server (CA) | Built from `docker/Dockerfile` |
| `ovadm-compiler01` | Compiler | Built from `docker/Dockerfile` |
| `ovadm-agent` | Agent (catalog verification) | `ghcr.io/openvoxproject/openvoxagent:latest` |

The agent is pre-configured (via `docker/agent-puppet.conf`) to request catalogs from `compiler01` and certificates from the server.

## Full Large topology test

```bash
# Build and start all three containers
docker compose build
docker compose up -d

# 1. Install the primary OpenVox Server
bolt plan run ovadm::install server_host=puppet \
  --inventoryfile docker/inventory.yaml

# 2. Add the compiler — sign_csr handles the compiler cert
bolt plan run ovadm::add_compiler \
  server_host=puppet compiler_hosts=compiler01 \
  --inventoryfile docker/inventory.yaml

# 3. Enable autosign so the agent cert is signed on first run
#    (bolt's docker transport doesn't shell-expand redirects; use docker exec directly)
docker exec ovadm-server bash -c 'echo "*" > /etc/puppetlabs/puppet/autosign.conf'

# 4. Run the agent — connects to compiler01 for catalog compilation
docker exec ovadm-agent /opt/puppetlabs/bin/puppet agent -t

# 5. Check status
bolt plan run ovadm::status server_host=puppet \
  --inventoryfile docker/inventory.yaml

# Tear down
docker compose down
```

## Upgrade test

To test a real upgrade, install the previous minor version first, then upgrade:

```bash
# Fresh containers at n-1
docker compose down && docker compose up -d

# Install at 8.12.1
bolt plan run ovadm::install server_host=puppet \
  ovox_server_version=8.12.1 \
  --inventoryfile docker/inventory.yaml

# Upgrade to current
bolt plan run ovadm::upgrade server_host=puppet \
  ovox_server_version=8.13.0 \
  --inventoryfile docker/inventory.yaml
```

The upgrade task actually downloads and installs the new package (vs the idempotent no-op when running the same version twice), so this exercises the full stop → install → restart → readiness path.

Note: `openvox-server 8.12.1` depends on `openvox-agent >= 8.21.1`, so yum resolves that to the latest available agent at install time. The agent is managed by the server package's dependency — ovadm does not separately pin it.

## OpenVoxDB test (co-located)

OpenVoxDB requires PostgreSQL 14 or later. Rocky Linux 9's default repo ships
PostgreSQL 13, so install PostgreSQL 15 from the pgdg repo before running the plan.

```bash
# Install PostgreSQL 15 on the server container
docker exec ovadm-server bash -c '
  dnf install -y -q https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-$(uname -m)/pgdg-redhat-repo-latest.noarch.rpm
  dnf -qy module disable postgresql
  dnf install -y -q postgresql15-server postgresql15-contrib
  /usr/pgsql-15/bin/postgresql-15-setup initdb
  systemctl enable --now postgresql-15
'

# Create the puppetdb database and user
docker exec ovadm-server bash -c "
  su - postgres -c \"psql -c \\\"CREATE USER puppetdb WITH PASSWORD 'puppetdb';\\\"\"
  su - postgres -c \"psql -c \\\"CREATE DATABASE puppetdb OWNER puppetdb;\\\"\"
  su - postgres -c \"psql -d puppetdb -c \\\"CREATE EXTENSION pg_trgm;\\\"\"
  sed -i 's/ident\$/md5/g; s/peer\$/md5/g' /var/lib/pgsql/15/data/pg_hba.conf
  systemctl reload postgresql-15
"

# Add OpenVoxDB (co-located on the server node)
bolt plan run ovadm::add_openvoxdb \
  server_host=puppet \
  db_password=puppetdb \
  --inventoryfile docker/inventory.yaml

# Verify: run puppet agent on the server and check PuppetDB received the report
docker exec ovadm-server /opt/puppetlabs/bin/puppet agent -t --server puppet
docker exec ovadm-server curl -s http://localhost:8080/pdb/query/v4/nodes
```

The `nodes` query should return a JSON array with the `puppet` node's certname and timestamps.

Note: OpenVoxDB listens on HTTPS port 8081 (mutual TLS, requires a client cert) and HTTP
port 8080 (localhost only, unauthenticated). The `wait_until_openvoxdb_ready` task polls
port 8080 since no client cert is needed for health checks.

## API access

Port 8140 is forwarded to `localhost:8140` on the server container:

```bash
curl -k https://localhost:8140/status/v1/simple
```

## Unit and acceptance tests

```bash
# Plan unit tests — no infrastructure required
bundle exec rake unit

# Acceptance tests — spin up a bare container, run tasks against it, tear down
docker run -d --name ovadm-acceptance rockylinux:9 sleep infinity
docker exec ovadm-acceptance bash -c "dnf install -y -q ca-certificates"
bundle exec rake acceptance
docker rm -f ovadm-acceptance
```

Acceptance tests run against a bare container (no puppetserver) and cover the `not_installed` paths and non-destructive tasks. Tests that require a live puppetserver are marked as TODO pending a more complete test harness.
