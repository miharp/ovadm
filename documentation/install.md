# Installing OpenVox Server with ovadm

> **Status:** Experimental — the `ovadm::install` plan is not yet implemented.

## Overview

The `ovadm::install` plan will automate the installation of a new OpenVox Server.

## Planned usage

```
bolt plan run ovadm::install \
  server_host=ovox.example.com \
  ovox_version=8.x.x
```

## Parameters

| Parameter        | Type                    | Description                                        |
|------------------|-------------------------|----------------------------------------------------|
| `server_host`    | TargetSpec              | The node to install OpenVox Server on              |
| `compiler_hosts` | Optional[TargetSpec]    | Compiler pool nodes (omit for Standard topology)   |
| `ovox_version`   | Optional[String]        | Target OpenVox Server version                      |
| `dns_alt_names`  | Optional[Array[String]] | Additional SAN entries for the certificate         |

## Contributing

See [CONTRIBUTING.md](../CONTRIBUTING.md) to help implement this plan.
