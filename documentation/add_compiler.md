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

To pin a specific `openvox-server` version on the compiler, pass `ovox_server_version`:

```bash
bolt plan run ovadm::add_compiler \
  server_host=ovox-server.example.com \
  compiler_hosts=ovox-compiler03.example.com \
  ovox_server_version=8.13.0
```

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
