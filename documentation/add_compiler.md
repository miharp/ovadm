# Managing compilers

## Adding a compiler

Add a compiler to an existing deployment at any time:

```bash
bolt plan run ovadm::add_compiler \
  server_host=ovox-server.example.com \
  compiler_hosts=ovox-compiler03.example.com
```

The plan:

1. Runs prechecks on the compiler node
2. Installs `openvox-server` and configures `puppet.conf` (pointing at the server as CA)
3. Embeds `pp_role: openvox_compiler` in the certificate via `csr_attributes.yaml`
4. Runs `puppet agent` to submit the CSR, signs it on the server, then runs the agent again to apply the initial catalog
5. Configures SSL for compiler-mode operation
6. Starts and enables `puppetserver`

The new compiler's certificate carries `$trusted['extensions']['pp_role'] == 'openvox_compiler'`, which Puppet code on the server can use for role-based classification without a node classifier.

The compiler gets the `openvox-server` version the server runs: the plan reads it from the server first, so a deployment upgraded to OpenVox 9 gets OpenVox 9 compilers. The plan stops if the server still runs Puppet Server; upgrade it with `ovadm::upgrade` first.

To install a different version on the compiler, such as a newer patch release, pass `ovox_server_version`:

```bash
bolt plan run ovadm::add_compiler \
  server_host=ovox-server.example.com \
  compiler_hosts=ovox-compiler03.example.com \
  ovox_server_version=8.13.0
```

`environment` sets the environment the compiler's agent asks for, from the
first run inside the plan on; see [Environment](install.md#environment). Pass
it when the deployment's pins live outside `production`, or that first run
applies `production`'s pins to the server package the plan just installed:

```bash
bolt plan run ovadm::add_compiler \
  server_host=ovox-server.example.com \
  compiler_hosts=ovox-compiler03.example.com \
  environment=openvox9
```

After adding compilers, size them with
[miharp-openvox_tune](https://forge.puppet.com/modules/miharp/openvox_tune):
run its plan against the server and every compiler together, so that the
server, which now compiles few catalogs, gets fewer JRuby instances and
compilers built alike get the same settings. See
[Sizing the server](install.md#sizing-the-server).

## What a compiler still needs from the site

`add_compiler` leaves the compiler able to answer on 8140 with a certificate
from the server's CA, and nothing more. Before it can compile a catalog that
is any use, the site has to give it what the server already has, and ovadm
does not carry any of it over:

- **Classification.** The compiler's first agent run happens inside the plan,
  against the server, so whatever the site's code does for an unknown node
  happens to the compiler then. Give it a role before running the plan: a
  node entry by certname, or a rule on
  `$trusted['extensions']['pp_role'] == 'openvox_compiler'`, which the plan
  puts in its certificate. If that role manages `openvox-server` (with
  [miharp-openvox_server](https://forge.puppet.com/modules/miharp/openvox_server)
  the CA is turned off with `ca => false` and `ca_server`), the same run
  takes over the files `configure_compiler_ssl` writes; the module writes
  them the same way, so nothing changes hands twice.
- **The environment**, where the deployment's pins live outside `production`:
  pass `environment`, as above.
- **The PuppetDB terminus.** A compiler stores facts and reports and answers
  `puppetdb_query` only with `openvoxdb-termini` installed and `puppetdb.conf`
  and `routes.yaml` pointed at the server's OpenVoxDB (`openvoxdb::master::config`
  from voxpupuli/puppet-openvoxdb, with `puppetdb_server` set to the server).
  OpenVoxDB accepts any certificate the CA signed, but its port, 8081, has to
  be open on the server to the compilers; a firewall that only opened 8140
  for the agents fails the terminus's connection check, and the role's run
  stops there, puppetserver unstarted.
- **Code.** r10k or Code Manager's equivalent on the compiler, with the same
  control-repo and deploy key as the server, and a timer or hook to keep it
  current. A compiler with no code compiles nothing.
- **Hiera secrets.** The eyaml keys, or whatever the site's lookups need,
  installed where the server has them.

Each of these is a site decision ovadm has no business making. The list is
what the Hetzner lab had to supply by hand around the plan, in that order.

## Removing a compiler

ovadm does not have a `remove_compiler` plan. The compiler is stateless — deleting the VM leaves no broken state on the server.

The one cleanup step is revoking the compiler's certificate from the CA, which is required if you ever want to reuse that hostname:

```bash
puppetserver ca clean --certname ovox-compiler03.example.com
```

Run this on the OpenVox Server node directly, or via `bolt command run` if you prefer not to SSH in.

If you skip this and later provision a new node with the same hostname, `ovadm::add_compiler` will detect the existing signed cert and skip signing (returning `already_signed`) — but the new node will be unable to connect because it has a different private key. Run `puppetserver ca clean` first in that case.

## Using an internal mirror

If compilers are on an air-gapped network, pass the same mirror parameters used during install:

```bash
bolt plan run ovadm::add_compiler \
  server_host=ovox-server.example.com \
  compiler_hosts=ovox-compiler03.example.com \
  apt_base_url=https://packages.example.com/vox-apt \
  yum_base_url=https://packages.example.com/vox-yum
```

## Using a parameter file

```bash
cp examples/add-compiler.json my-add-compiler.json
# edit with your hostnames
bolt plan run ovadm::add_compiler --params @my-add-compiler.json
```

Example contents of `examples/add-compiler.json`:

```json
{
  "server_host": "ovox-server.example.com",
  "compiler_hosts": "ovox-compiler03.example.com"
}
```

Add `apt_base_url` or `yum_base_url` if you need an internal package mirror.
