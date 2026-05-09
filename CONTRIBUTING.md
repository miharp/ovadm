# Contributing to ovadm

ovadm is an experimental, community-driven project. Contributions of all kinds are welcome.

## What we need most

The plans in this module are currently stubs. The highest-value contributions right now are:

1. Implementing `ovadm::install` — automate a fresh OpenVox Server deployment
2. Implementing `ovadm::upgrade` — automate in-place version upgrades
3. Implementing `ovadm::status` — surface service and API health
4. Testing across supported platforms (RHEL, Debian, Ubuntu, Rocky)

## Getting started

### Ruby

This project requires Ruby >= 3.2. Do not use your system Ruby — use a version manager instead.

**rbenv** (recommended):

```bash
rbenv install 3.2.11   # or any 3.2.x / 3.3.x
rbenv local 3.2.11     # writes .ruby-version; rbenv picks it up automatically
```

**rvm**:

```bash
rvm install 3.2.11
rvm use 3.2.11
```

### Dependencies

```bash
gem install bundler
bundle install
```

### Bolt

Install Bolt separately — it is not a bundled gem:
[Bolt installation docs](https://www.puppet.com/docs/bolt/latest/bolt_installing.html)

### Running tests locally

Tests use [puppet_litmus](https://github.com/puppetlabs/puppet_litmus) with Docker. You need Docker running.

```bash
# Provision a test container (Ubuntu 22.04)
bundle exec rake 'litmus:provision_list[default]'

# Run acceptance tests against it
bundle exec rake 'litmus:acceptance:parallel'

# Tear down when done
bundle exec rake litmus:tear_down
```

To test against Rocky Linux 9 instead:

```bash
bundle exec rake 'litmus:provision_list[rocky9]'
```

Read the [OpenVox documentation](https://docs.openvoxproject.org) for background on the server you're automating.

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
