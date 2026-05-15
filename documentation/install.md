# Installing OpenVox Server with ovadm

## Prerequisites

- [OpenBolt](https://github.com/OpenVoxProject/openbolt) installed (`gem install openbolt`)
- An inventory file — copy `inventory.yaml.example` to `inventory.yaml` and fill in your target details
- A supported Linux target with network access to install packages

See the [README](../README.md) for the full requirements list.

## Standard topology

A single OpenVox Server node managing agents directly.

```bash
bolt plan run ovadm::install server_host=ovox-server.example.com
```

The plan:

1. Runs prechecks (OS, Java, port 8140, NTP)
2. Configures the OpenVox package repository
3. Installs `openvox-server`
4. Writes `puppet.conf`
5. Embeds `pp_role: openvox_server` in the server certificate
6. Starts and enables `puppetserver`
7. Waits for the service to respond on port 8140

## Large topology

An OpenVox Server plus one or more compilers that distribute catalog compilation.

```bash
bolt plan run ovadm::install \
  server_host=ovox-server.example.com \
  compiler_hosts=ovox-compiler01.example.com,ovox-compiler02.example.com
```

Additional steps for each compiler:

1. Installs `openvox-server` on the compiler
2. Configures `puppet.conf` to point at the server as CA
3. Embeds `pp_role: openvox_compiler` in the compiler certificate
4. Runs `puppet agent` to submit and sign the CSR
5. Starts `puppetserver` on the compiler

## DNS alt names

If agents connect to the server via a load balancer hostname or alias, embed it in the server certificate at install time:

```bash
bolt plan run ovadm::install \
  server_host=ovox-server.example.com \
  dns_alt_names='["puppet","puppet.example.com","ovox-lb.example.com"]'
```

> **Note:** DNS alt names must be set before the CA certificate is generated on first start. They cannot be changed after the service has run without wiping the SSL directory.

## Version parameters

`openvox-server` and `openvox-agent` are versioned independently. The server package has a minimum agent version dependency, so the package manager installs a compatible agent automatically.

| Parameter | Controls | Example |
| --------- | -------- | ------- |
| `ovox_server_version` | `openvox-server` package pinned to an exact version; omit for latest | `8.13.0` |
| `ovox_version` | Selects the major package repo (`openvox8` vs `openvox9`); only needed when targeting a different major release line | `8.26.2` |

To pin a specific server version:

```bash
bolt plan run ovadm::install \
  server_host=ovox-server.example.com \
  ovox_server_version=8.13.0
```

Both parameters are optional. When `ovox_version` is omitted, the major repo is derived from `ovox_server_version` (or defaults to openvox8). If both are set, they should target the same major line.

## Internal package mirror

If your nodes cannot reach the public VoxPupuli repositories, point `apt_base_url` and/or `yum_base_url` at an internal mirror:

```bash
bolt plan run ovadm::install \
  server_host=ovox-server.example.com \
  apt_base_url=https://packages.example.com/vox-apt \
  yum_base_url=https://packages.example.com/vox-yum
```

Both parameters are optional and default to the public repos. Pass them to `ovadm::add_compiler` as well if compilers are on an air-gapped network.

## Using a parameter file

For repeatable runs or complex topologies, use a JSON parameter file instead of CLI arguments. The `examples/` directory contains starter files for each topology.

Copy and edit the relevant file:

```bash
cp examples/install-large.json my-install.json
# edit my-install.json with your hostnames
bolt plan run ovadm::install --params @my-install.json
```

Example contents of `examples/install-large.json`:

```json
{
  "server_host": "ovox-server.example.com",
  "compiler_hosts": "ovox-compiler01.example.com,ovox-compiler02.example.com",
  "dns_alt_names": ["puppet", "puppet.example.com", "ovox-lb.example.com"]
}
```

`dns_alt_names` is optional. Add `apt_base_url` or `yum_base_url` only if you need an internal package mirror.

## Verifying the install

```bash
bolt plan run ovadm::status server_host=ovox-server.example.com
```

Or for a quick machine-readable snapshot:

```bash
bolt task run ovadm::infrastatus --targets ovox-server.example.com
```
