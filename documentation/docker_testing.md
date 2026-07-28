# Local Docker testing

`docker-compose.yml` defines a three-node environment using Rocky Linux 9 with systemd for end-to-end testing without real infrastructure.

## Containers

| Container | Role | Image |
| --------- | ---- | ----- |
| `ovadm-server` | OpenVox Server (CA) | Built from `docker/Dockerfile` |
| `ovadm-compiler01` | Compiler | Built from `docker/Dockerfile` |
| `ovadm-agent` | Agent (catalog verification) | `ghcr.io/openvoxproject/openvoxagent:latest` |

The server and compiler both run codavox once step 3 below is applied: the server
publishes, the compiler pulls and serves catalogs from what it pulled.

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

# 3. Install and wire codavox, so the compiler serves versioned code
bolt plan run ovadm::codavox \
  server_host=puppet compiler_hosts=compiler01 \
  --inventoryfile docker/inventory.yaml

# 4. Enable autosign so the agent cert is signed on first run
#    (bolt's docker transport doesn't shell-expand redirects; use docker exec directly)
docker exec ovadm-server bash -c 'echo "*" > /etc/puppetlabs/puppet/autosign.conf'

# 5. Run the agent — connects to compiler01 for catalog compilation
docker exec ovadm-agent /opt/puppetlabs/bin/puppet agent -t

# 6. Check status
bolt plan run ovadm::status server_host=puppet \
  --inventoryfile docker/inventory.yaml

# Tear down
docker compose down
```

## Verifying codavox actually did something

Step 3 is easy to believe on the strength of its own success message. The check
that means something is whether the catalog the agent just compiled carries the
`code_id` compiler01 says it is serving. Without codavox wired, the catalog has
no `code_id` at all — and an ordinary catalog is not an error, so nothing
complains:

```console
served=$(docker exec ovadm-compiler01 codavox code-id production)
docker exec ovadm-agent grep -o '"code_id":"[^"]*"' \
  /opt/puppetlabs/puppet/cache/client_data/catalog/agent.json | head -1
# the two must agree
```

The publisher's fleet view should name the same version. It is self-reported —
each agent says what its own environment symlink points at — so agreement here
means the compiler and the publisher have not drifted:

```console
docker exec ovadm-server codavox compilers
```

The same two checks run in `.github/workflows/install-test.yml` on the `large`
topology.

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
