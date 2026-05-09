# Upgrading OpenVox Server with ovadm

> **Status:** Experimental — the `ovadm::upgrade` plan is not yet implemented.

## Overview

The `ovadm::upgrade` plan will automate in-place upgrades of an existing OpenVox Server deployment.

## Planned usage

```
bolt plan run ovadm::upgrade \
  primary_host=ovox-primary.example.com \
  ovox_version=8.x.x
```

## Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `primary_host` | TargetSpec | The node running OpenVox Server |
| `ovox_version` | Optional[String] | Target version to upgrade to |

## Contributing

See [CONTRIBUTING.md](../CONTRIBUTING.md) to help implement this plan.
