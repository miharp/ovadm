# Contributing to ovadm

ovadm is an experimental, community-driven project. Contributions of all kinds are welcome.

## What we need most

The plans in this module are currently stubs. The highest-value contributions right now are:

1. Implementing `ovadm::install` — automate a fresh OpenVox Server deployment
2. Implementing `ovadm::upgrade` — automate in-place version upgrades
3. Implementing `ovadm::status` — surface service and API health
4. Testing across supported platforms (RHEL, Debian, Ubuntu, Rocky)

## Getting started

1. Fork this repository
2. Install dependencies:
   ```
   gem install bundler
   bundle install
   ```
3. Install Bolt: https://www.puppet.com/docs/bolt/latest/bolt_installing.html
4. Read the [OpenVox documentation](https://docs.openvoxproject.org)

## Code style

- Puppet code follows the [Puppet Language Style Guide](https://www.puppet.com/docs/puppet/latest/style_guide.html)
- Bolt plans use `.pp` (Puppet) format unless a YAML plan is cleaner
- Shell tasks use `set -euo pipefail`

## Pull requests

- Open an issue first for significant changes
- Keep PRs focused — one logical change per PR
- Include tests where feasible

## Community

This project may move under the OpenVox project organization if it gains community support. If you're interested in helping maintain it long-term, open an issue to discuss.
