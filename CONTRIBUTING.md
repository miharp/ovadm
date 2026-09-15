# Contributing to ovadm

ovadm is an experimental, community-driven project. Contributions of all kinds are welcome.

## What we need most

The core plans (install, upgrade, status, add_compiler) are implemented and tested. The highest-value contributions right now are:

1. **Bug reports and fixes** — if something breaks on a supported platform, open an issue with OS, OpenVox version, and the full Bolt output
2. **Broader platform testing** — CI covers Rocky 9, Ubuntu 22.04/24.04, Debian 12; feedback on other platforms is welcome
3. **Internal mirror / air-gap scenarios** — the `apt_base_url`/`yum_base_url` params exist but haven't been validated against real Artifactory or Nexus setups
4. **OpenVoxDB integration** — wiring up `openvoxdb` and `openvoxdb-termini` as an optional post-install step is unimplemented

See [`documentation/plan.md`](documentation/plan.md) for the full task catalog and roadmap.

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

### OpenBolt

Install OpenBolt as a gem:

```bash
gem install openbolt
```

### Running tests locally

```bash
# Plan unit tests — no infrastructure required
bundle exec rake unit

# Acceptance tests — requires a running Docker container
docker run -d --name ovadm-acceptance rockylinux:9 sleep infinity
docker exec ovadm-acceptance bash -c "dnf install -y -q ca-certificates"
bundle exec rake acceptance
docker rm -f ovadm-acceptance
```

For a full end-to-end test using the three-node Docker environment, see [Docker testing](documentation/docker_testing.md).

## Code style

- Puppet plans follow the [Puppet Language Style Guide](https://www.puppet.com/docs/puppet/latest/style_guide.html)
- Shell tasks use `set -euo pipefail` and output valid JSON on stdout
- Task metadata (`.json`) must define `input_method`, `parameters`, and `supports_noop`

## Pull requests

- The `main` branch is protected — always work on a branch and open a PR
- Open an issue first for significant changes
- Keep PRs focused — one logical change per PR
- Include tests: BoltSpec unit tests for plan logic, acceptance specs for new tasks

## Community

This project may move under the OpenVox project organization if it gains community support. If you're interested in helping maintain it long-term, open an issue to discuss.

## Releasing

Releases are git tags. There is no package and nothing is published to the Forge —
a tag is what a `Puppetfile` pins, so cutting one is the whole release.

1. In a PR: add the version's section to `CHANGELOG.md` and set the same version
   in `metadata.json`. While ovadm is in 0.x, a minor bump covers breaking
   changes; reserve patch bumps for fixes.
2. After it merges, tag the merge commit on `main` and push:

   ```bash
   git checkout main && git pull
   git tag -a v0.2.0 -m 'v0.2.0'
   git push origin v0.2.0
   ```

The `Release` workflow takes it from there: it refuses the tag if `metadata.json`
disagrees with it or if `CHANGELOG.md` has no entry for that version, then
publishes a GitHub release using that entry as the notes.
