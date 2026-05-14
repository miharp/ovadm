# Upgrading OpenVox Server with ovadm

## Standard topology

```bash
bolt plan run ovadm::upgrade \
  server_host=ovox-server.example.com \
  ovox_version=8.4.0
```

The plan stops the service, installs the target version, restarts, waits for readiness, and confirms the installed version matches.

## Large topology

```bash
bolt plan run ovadm::upgrade \
  server_host=ovox-server.example.com \
  compiler_hosts=ovox-compiler01.example.com,ovox-compiler02.example.com \
  ovox_version=8.4.0
```

The server is upgraded first, then all compilers. Compilers are currently upgraded simultaneously — plan for a brief compilation outage during the compiler restart window, or take them out of your load balancer rotation beforehand.

## Major version upgrades

The `upgrade` plan calls `install_server` directly against the already-configured package repo. This works for **minor and patch upgrades within the same major version** (e.g. 8.3.x → 8.4.0).

For a **major version upgrade** (e.g. 8.x → 9.x), the release package must be updated first to point at the new repo. Run `ovadm::configure_repo` manually on each node before upgrading:

```bash
bolt task run ovadm::configure_repo ovox_major=9 --targets ovox-server.example.com
bolt plan run ovadm::upgrade server_host=ovox-server.example.com ovox_version=9.0.0
```
