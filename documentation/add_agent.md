# Adding agents

## Adding an agent

`ovadm::add_agent` turns stock hosts into agents of an existing deployment,
from the workstation, with no step run on the hosts by hand:

```bash
bolt plan run ovadm::add_agent \
  server_host=ovox-server.example.com \
  agent_hosts=agent01.example.com,agent02.example.com
```

The plan:

1. Runs prechecks on the agent hosts: a supported OS family and time sync.
   An agent needs no Java, no heap memory and no open 8140, so those checks
   are left out
2. Configures the OpenVox package repository and installs `openvox-agent`
3. Writes `puppet.conf`, with `server` set to the server (or to
   `agent_server`, below), `ca_server` always the server, and `environment`
   when given. Directory settings an existing `[main]` section carries
   (`vardir`, `ssldir`, `logdir`, `rundir`, `codedir` and the SSL
   subdirectories) are kept, so a host that Foreman provisioned with its
   Puppet 3 fallback layout, certificates under `/var/lib/puppet/ssl`, goes
   on finding them
4. Sets the `pp_role` extension in `csr_attributes.yaml`, when given
   (see [Classifying by pp_role](#classifying-by-pp_role))
5. Runs `puppet agent` on every host to submit its CSR, signs each on the
   server, then runs the agent again so every host applies its first catalog
   inside the plan, as compilers do

Each host's first catalog is whatever the site's code does for an unknown
node. Give the hosts a role before running the plan (a node entry by
certname, a rule on a fact, or a `pp_role` in the certificate, below) if
that first run should do something.

## Classifying by pp_role

Sites that classify nodes on a trusted certificate extension can have the
plan put a role in the agents' certificates:

```bash
bolt plan run ovadm::add_agent \
  server_host=ovox-server.example.com \
  agent_hosts=web01.example.com,web02.example.com \
  pp_role=webserver
```

The plan writes `csr_attributes.yaml` with that `pp_role` before the first
agent run, so each host's certificate request asks for it and the signed
certificate carries it. The site's code sees it as
`$trusted['extensions']['pp_role']` from the first run inside the plan on,
for instance with `include "role::${trusted['extensions']['pp_role']}"`.
The server and compilers carry `pp_role` the same way; see
[Certificate role extensions](architecture.md#certificate-role-extensions).

- **One role per run.** Every host in the run gets the same role, so hosts
  with different roles go in separate runs of the plan.
- **The rest of the file is kept.** Where a host already has a
  `csr_attributes.yaml` (with a `challengePassword` for policy-based
  autosigning, say, or extensions of the site's own), the plan sets
  `pp_role` in it and keeps everything else. A role already in the file,
  under `pp_role` or its OID, is replaced. The merge reads the file as YAML,
  so comments in it do not survive a change; a file that already has the
  role is not rewritten. A file the agent could not read either (not YAML,
  or with top-level keys other than `custom_attributes` and
  `extension_requests`) fails the host and is left as it is. Without
  `pp_role` the plan does not touch the file.
- **The value** is letters, digits and `_`, `.`, `:` or `-`, starting with a
  letter or digit, so `webserver` and `role::webserver` both work.
  `openvox_server` and `openvox_compiler` are refused: they are the roles
  ovadm gives the server and compilers, and a site that classifies compilers
  on `openvox_compiler` would turn an agent given it into a compiler on its
  first run.
- **The role is fixed at signing.** A host that already has a certificate
  keeps the role it was signed with: rerunning the plan with another
  `pp_role` rewrites the file and changes nothing in the certificate. To
  change a host's role, clean its certificate on the server
  (`puppetserver ca clean --certname <host>`), remove the host's `ssldir`
  (`puppet config print ssldir` names it; `/etc/puppetlabs/puppet/ssl` unless
  the site moved it), and run the plan again.

The agent service is left as the package leaves it: ovadm does not schedule
runs, by service, cron or timer. That is the site's choice, like the rest of
what runs on the node.

## Pointing agents at a compiler or load balancer

On a Large topology, agents should ask the compilers for catalogs and leave
the server to the CA and the compilers' own catalogs. `agent_server` is the
name written as `server` in their `puppet.conf`: a compiler's FQDN, or the
name of the load balancer in front of the pool. The CA is always the server,
whatever `agent_server` says.

```bash
bolt plan run ovadm::add_agent \
  server_host=ovox-server.example.com \
  agent_hosts=agent01.example.com \
  agent_server=ovox-lb.example.com
```

A load balancer name has to be in the compilers' certificates, which it is
when `ovadm::install` was given it in `dns_alt_names`; see
[DNS alt names](install.md#dns-alt-names).

`agent_server` holds until the site's code says otherwise. Agent profiles
often manage `server` in `puppet.conf` themselves (theforeman-puppet does,
and so do many sites' own), and the first catalog inside the plan applies
theirs. The plan reads the setting back afterwards and reports where each
host was left, with a warning where that is not `agent_server`:

```text
WARNING agent01.example.com: enrolled, but its first catalog changed server in puppet.conf from ovox-compiler01.example.com to ovox-server.example.com, so it gets catalogs from ovox-server.example.com. The site's code manages that setting; set it there.
```

The plan's result carries the same thing as `servers`, the setting each
host's `puppet.conf` names. To keep agents on the compilers, give the site's
profile the same name as `agent_server`.

## Versions

The agents get the newest `openvox-agent` of the major the server runs: the
plan reads the server's `openvox-server` version first, so an estate on
OpenVox 9 gets OpenVox 9 agents. It stops if the server still runs Puppet
Server; upgrade it with `ovadm::upgrade` first, or pass `ovox_version`.

To install a specific version, pass it; the major repository follows from it:

```bash
bolt plan run ovadm::add_agent \
  server_host=ovox-server.example.com \
  agent_hosts=agent01.example.com \
  ovox_version=8.30.0
```

Later upgrades of the agents are a Puppet run's job, with
[miharp-openvox_agent](https://forge.puppet.com/modules/miharp/openvox_agent)
or the site's own code; ovadm does not upgrade agents.

## Environment

`environment` sets the environment the agents ask for, from the first run
inside the plan on; see [Environment](install.md#environment). The
environment must exist on the server already. The plan runs the agents with
`--environment`, so a run against an environment the server does not have
fails for that host, rather than succeeding against `production` and leaving
the host there.

```bash
bolt plan run ovadm::add_agent \
  server_host=ovox-server.example.com \
  agent_hosts=agent01.example.com \
  environment=demo
```

## Signing

The plan signs each host's certificate on the server, as `add_compiler` does.
Where the CA autosigns, the first run already gets a certificate and applies
the catalog, and the signing step reports `already_signed`; nothing has to be
turned off for the plan.

Running the plan again against a host that is already an agent is safe: the
packages are already there, `puppet.conf` is rewritten with the same values,
the certificate is already signed, and the two agent runs apply the current
catalog.

## When a host fails

A batch does not stop at the first bad host. A host that fails a step (the
package will not install, the CA never saw its request, its first run applied
nothing) is left out of the following steps, and the plan goes on with the
rest. At the end it lists the hosts that were enrolled and then fails, naming
each host that was not and why:

```text
agent01.example.com: enrolled, getting catalogs from ovox-server.example.com
ovadm::add_agent failed on 1 of 2 agent(s):
agent02.example.com: No certificate request found for the following nodes when attempting to sign: agent02.example.com
```

Fix the host and run the plan again with that host alone. The prechecks are
the exception: they run before anything is changed, and a host that fails
them stops the plan, since nothing has been started yet.

## Removing an agent

ovadm has no `remove_agent` plan. Clean the certificate on the server so the
hostname can be enrolled again:

```bash
puppetserver ca clean --certname agent01.example.com
```

A new host with the same name enrolled without that step gets
`already_signed` from the plan and then fails to connect, since it has a
different key.

## Using an internal mirror

Pass the same mirror parameters used during the install:

```bash
bolt plan run ovadm::add_agent \
  server_host=ovox-server.example.com \
  agent_hosts=agent01.example.com \
  apt_base_url=https://packages.example.com/vox-apt \
  yum_base_url=https://packages.example.com/vox-yum
```

## Using a parameter file

```bash
cp examples/add-agent.json my-add-agent.json
# edit with your hostnames
bolt plan run ovadm::add_agent --params @my-add-agent.json
```

Example contents of `examples/add-agent.json`:

```json
{
  "server_host": "ovox-server.example.com",
  "agent_hosts": ["agent01.example.com", "agent02.example.com"],
  "agent_server": "ovox-compiler01.example.com"
}
```

## Only the package, or Windows

[voxpupuli/puppet-openvox_bootstrap](https://github.com/voxpupuli/puppet-openvox_bootstrap)
installs `openvox-agent` on EL, Debian, Ubuntu, Fedora and Windows, with Bolt
tasks that run on the node and an `apply_prep` hook. It does not enroll the
node. Use it where only the package is wanted, or for a platform ovadm does
not install on; `add_agent` is for hosts on the platforms ovadm tests, that
should come out the other side as enrolled agents.
