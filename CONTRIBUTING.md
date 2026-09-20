# Contributing to ovadm

ovadm is an experimental, community-driven project. Contributions of all kinds are welcome.

## What we need most

The core plans (install, upgrade, status, add_compiler) are implemented and tested. The highest-value contributions right now are:

1. **Bug reports and fixes** — if something breaks on a supported platform, open an issue with OS, OpenVox version, and the full Bolt output
2. **Broader platform testing** — CI covers Rocky 9, Ubuntu 22.04/24.04, Debian 12, all in Docker. AlmaLinux 9 and 10 have been run by hand on cloud VMs (see [Testing on real VMs](#testing-on-real-vms)); feedback on other platforms is welcome
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

### Testing on real VMs

Everything in CI runs in Docker over Bolt's docker transport. That leaves real
systemd, the SSH transport, SELinux and the host firewall untested, so a run
against throwaway cloud VMs is worth doing before a release or when adding a
platform. Any provider works; three small VMs (2 vCPU, 4 GB) cover Standard and
Large, and the whole pass takes about ten minutes.

The VMs need a resolvable FQDN each (`hostname -f` must return it, and the
compilers must resolve the server's — `/etc/hosts` entries are enough), root
SSH from your workstation, and nothing else: no Java, no OpenVox packages.

```yaml
# inventory.yaml — gitignored
config:
  transport: ssh
  ssh:
    user: root
    host-key-check: false   # throwaway VMs get new host keys on every rebuild

targets:
  - name: server
    uri: 203.0.113.10
  - name: compiler01
    uri: 203.0.113.11
```

```bash
bolt plan run ovadm::install      server_host=server
bolt plan run ovadm::status       server_host=server
bolt plan run ovadm::add_compiler server_host=server compiler_hosts=compiler01
bolt plan run ovadm::install      server_host=server   # rerun: must leave the CA and signed certs alone
```

Then check what the plans cannot see for themselves:

- `puppetserver ca list --all` on the server shows every node, and
  `grep -c 'BEGIN CERTIFICATE' /etc/puppetlabs/puppetserver/ca/ca_crt.pem` returns 2
- `puppet agent -t --server <compiler fqdn>` from another node reports
  `Catalog compiled by <compiler fqdn>`
- port 8140 answers from a *different* machine, not just localhost — see the
  firewall note in [Installing](documentation/install.md#verifying-the-install)

Cloud images often ship with SELinux permissive and no firewall running. To
test those, turn them on before the install (`setenforce 1`,
`systemctl enable --now firewalld`) and look for denials afterwards with
`ausearch --input-logs -m avc -ts boot` (without `--input-logs`, `ausearch`
waits on stdin when run through `bolt command run`).

Delete the VMs when you are done, and check the provider's server list to be
sure they are gone.

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

A release is a git tag. Pushing one publishes the module to the
[Forge](https://forge.puppet.com/modules/miharp/ovadm) and cuts a GitHub release
from the same commit, so a `Puppetfile` can pin either and get the same code.

1. In a PR: add the version's section to `CHANGELOG.md`, set the same version in
   `metadata.json`, and update the version in the README's `Puppetfile`
   examples. While ovadm is in 0.x, a minor bump covers breaking changes;
   reserve patch bumps for fixes.
2. After it merges, tag the merge commit on `main` and push:

   ```bash
   git checkout main && git pull
   git tag -a v0.4.0 -m 'v0.4.0'
   git push origin v0.4.0
   ```

The `Release` workflow takes it from there, in three jobs:

1. **gates** refuses the tag if `metadata.json` disagrees with it or if
   `CHANGELOG.md` has no entry for that version.
2. **release** is Vox Pupuli's shared
   [release workflow](https://github.com/voxpupuli/gha-puppet/blob/v4/.github/workflows/release.yml),
   called exactly as [puppet-headscale](https://github.com/miharp/puppet-headscale)
   calls it. It runs `rake module:push` (build, then upload to the Forge) and
   creates the GitHub release with the tarball attached. It runs in a GitHub
   environment named `release`, where approval rules can be added.
3. **notes** replaces the release's generated notes with the changelog entry.

The Forge upload comes before the GitHub release. If it fails, nothing exists
but the tag: fix the cause and re-run the workflow. Once the Forge has accepted
a version, that number is spent. A release can be deleted from the Forge but
never uploaded again, so a bad release is fixed by shipping the next patch
version, not by moving the tag.

The upload needs two repository secrets, `PUPPET_FORGE_USERNAME` and
`PUPPET_FORGE_API_KEY` (a key from the Forge account's profile page).

The package holds only what a Bolt module needs: `plans/`, `tasks/`,
`examples/`, `README.md`, `LICENSE`, `CHANGELOG.md` and `metadata.json`. The
builder works from a fixed list, so `documentation/`, the specs and the Docker
environment stay out. That is why README links are absolute: the Forge renders
the README on its own. To see exactly what would ship:

```bash
bundle exec rake module:build && tar -tzf pkg/*.tar.gz
```

CI runs the same build on every pull request.

The release tooling is `voxpupuli-release`, as in puppet-headscale, but only its
`module:build` and `module:push` tasks are used here. ovadm keeps a hand-written
changelog and sets the version in the release PR, so the gem's
`release:prepare` (generated changelog) and `-rc0` version bumps are not part of
this flow.
