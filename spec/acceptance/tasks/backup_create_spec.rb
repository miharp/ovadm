# frozen_string_literal: true

require 'spec_helper'
require 'json'

# The container has no OpenVox, so the tree a primary server would have is
# laid out by hand: a CA, the server's certificate, configuration, a deployed
# environment, a database.ini, and a deploy key outside the tree.
RSpec.describe 'ovadm::backup_create task' do
  let(:destination) { '/var/backups/openvox' }
  let(:fqdn) { run_shell('hostname -f 2>/dev/null || hostname')['stdout'].strip }

  def seed_primary
    run_shell(<<~SH)
      set -e
      rm -rf /etc/puppetlabs /etc/sysconfig/puppetserver /etc/default/puppetserver /root/.ssh/deploy_key /etc/puppetlabs-eyaml
      install -d -m 0750 /etc/puppetlabs/puppetserver/ca/signed /etc/puppetlabs/puppetserver/ca/requests
      echo CAKEY > /etc/puppetlabs/puppetserver/ca/ca_key.pem; chmod 0640 /etc/puppetlabs/puppetserver/ca/ca_key.pem
      echo CACRT > /etc/puppetlabs/puppetserver/ca/ca_crt.pem
      printf '0x0005\\n' > /etc/puppetlabs/puppetserver/ca/serial
      printf '0x0001 2026-10-01T00:00:00UTC 2031-10-01T00:00:00UTC /CN=agent01\\n' > /etc/puppetlabs/puppetserver/ca/inventory.txt
      echo AGENTCRT > /etc/puppetlabs/puppetserver/ca/signed/agent01.pem
      install -d -m 0771 /etc/puppetlabs/puppet/ssl/certs /etc/puppetlabs/puppet/ssl/private_keys
      echo HOSTCRT > /etc/puppetlabs/puppet/ssl/certs/host.pem
      echo HOSTKEY > /etc/puppetlabs/puppet/ssl/private_keys/host.pem; chmod 0600 /etc/puppetlabs/puppet/ssl/private_keys/host.pem
      printf '[main]\\ncertname = host\\n' > /etc/puppetlabs/puppet/puppet.conf
      install -d /etc/puppetlabs/puppetserver/conf.d
      echo 'webserver: {}' > /etc/puppetlabs/puppetserver/conf.d/webserver.conf
      install -d -m 0700 /etc/puppetlabs/puppetdb/ssl /etc/puppetlabs/puppetdb/conf.d
      echo PDBCRT > /etc/puppetlabs/puppetdb/ssl/host.pem
      printf '[database]\\nsubname = //localhost:5432/puppetdb\\nusername = puppetdb\\npassword = s3cret\\n' > /etc/puppetlabs/puppetdb/conf.d/database.ini
      install -d /etc/puppetlabs/code/environments/production/manifests /etc/puppetlabs/code/environments/production/modules/openvox_server
      echo 'node default {}' > /etc/puppetlabs/code/environments/production/manifests/site.pp
      echo '{"name":"production","signature":"abc123def","started_at":"2026-10-20T10:00:00+00:00","finished_at":"2026-10-20T10:00:05+00:00","deploy_success":true}' > /etc/puppetlabs/code/environments/production/.r10k-deploy.json
      printf 'version: 5\\ndefaults:\\n  options:\\n    pkcs7_private_key: /etc/puppetlabs-eyaml/private_key.pkcs7.pem\\n' > /etc/puppetlabs/code/environments/production/hiera.yaml
      echo '{"name":"miharp-openvox_server","version":"0.1.1"}' > /etc/puppetlabs/code/environments/production/modules/openvox_server/metadata.json
      if [ -d /etc/sysconfig ]; then echo 'JAVA_ARGS="-Xmx2g"' > /etc/sysconfig/puppetserver; else mkdir -p /etc/default; echo 'JAVA_ARGS="-Xmx2g"' > /etc/default/puppetserver; fi
      install -d -m 0700 /root/.ssh
      echo DEPLOYKEY > /root/.ssh/deploy_key; chmod 0600 /root/.ssh/deploy_key
      rm -rf #{destination}
    SH
  end

  def listing(archive)
    run_shell("tar -tzf #{archive}")['stdout'].lines.map(&:strip)
  end

  def verbose_listing(archive)
    run_shell("tar -tvzf #{archive}")['stdout']
  end

  def read_from(archive, member)
    run_shell("tar -xzOf #{archive} #{member}")['stdout']
  end

  before { seed_primary }

  context 'with everything on' do
    it 'writes one archive of the CA, certificates, configuration and deployed code record' do
      result = run_bolt_task('ovadm::backup_create')
      expect(result.exit_code).to eq(0)
      data = result.result
      expect(data['status']).to eq('created')
      expect(data['archive']).to match(%r{\A#{destination}/openvox-backup-#{Regexp.escape(fqdn)}-\d{8}T\d{6}Z\.tar\.gz\z})
      expect(data['certname']).to eq(fqdn)
      expect(data['ca_serial_moved']).to be(false)
      expect(data['services_stopped']).to eq([])
      expect(data['size_bytes']).to be > 0
      expect(run_shell("stat -c %a #{data['archive']}")['stdout'].strip).to eq('600')
      expect(run_shell("stat -c %a #{destination}")['stdout'].strip).to eq('700')
      expect(run_shell("ls -A #{destination}")['stdout'].split).to eq([File.basename(data['archive'])])

      name = File.basename(data['archive'], '.tar.gz')
      members = listing(data['archive'])
      expect(members).to include(
        "#{name}/files/etc/puppetlabs/puppetserver/ca/ca_key.pem",
        "#{name}/files/etc/puppetlabs/puppetserver/ca/signed/agent01.pem",
        "#{name}/files/etc/puppetlabs/puppet/ssl/private_keys/host.pem",
        "#{name}/files/etc/puppetlabs/puppet/puppet.conf",
        "#{name}/files/etc/puppetlabs/puppetserver/conf.d/webserver.conf",
        "#{name}/files/etc/puppetlabs/puppetdb/ssl/host.pem",
        "#{name}/files/etc/puppetlabs/puppetdb/conf.d/database.ini",
        "#{name}/files/etc/puppetlabs/code/environments/production/.r10k-deploy.json",
        "#{name}/files/etc/puppetlabs/code/environments/production/hiera.yaml",
        "#{name}/ovadm/manifest.json", "#{name}/ovadm/topology.json", "#{name}/ovadm/SHA256SUMS"
      )
      expect(members.grep(%r{/files/etc/(sysconfig|default)/puppetserver$}).size).to eq(1)
      expect(members).not_to include("#{name}/files/etc/puppetlabs/code/environments/production/manifests/site.pp")
      expect(members).not_to include("#{name}/files/etc/puppetlabs/code/environments/production/modules/openvox_server/metadata.json")
      expect(members.grep(%r{/root/})).to be_empty

      manifest = JSON.parse(read_from(data['archive'], "#{name}/ovadm/manifest.json"))
      expect(manifest).to include('format' => 1, 'name' => name, 'certname' => fqdn, 'created' => data['created'])
      expect(manifest['backup']).to include('ca' => true, 'config' => true, 'code' => true, 'include_code_tree' => false, 'extra_paths' => [])
      expect(manifest['ca']).to eq('serial_before' => '0x0005', 'serial_after' => '0x0005', 'serial_moved' => false)
      expect(manifest['environments']).to eq('production' => { 'signature' => 'abc123def', 'deployed' => '2026-10-20T10:00:05+00:00' })
      expect(manifest['openvox_server_module']).to eq('in_last_catalog' => false, 'version' => '0.1.1')
      expect(manifest['packages'].keys).to include('openvox-server', 'openvoxdb')
      expect(manifest['files']).to eq(data['files'])
      expect(manifest['files']).to eq(members.count { |m| m.include?('/files/') && !m.end_with?('/') })

      topology = JSON.parse(read_from(data['archive'], "#{name}/ovadm/topology.json"))
      expect(topology['certname']).to eq(fqdn)
      expect(topology['ca']).to be(true)
      expect(topology['openvoxdb']['database']).to include('host' => 'localhost', 'name' => 'puppetdb')

      sums = read_from(data['archive'], "#{name}/ovadm/SHA256SUMS")
      expect(sums).to include('files/etc/puppetlabs/puppetserver/ca/ca_key.pem', 'ovadm/manifest.json', 'ovadm/topology.json')
      check = run_shell("cd /tmp && rm -rf chk && mkdir chk && tar -xzf #{data['archive']} -C chk && cd chk/#{name} && sha256sum --quiet -c ovadm/SHA256SUMS && echo SUMS_OK")
      expect(check['stdout']).to include('SUMS_OK')
    end

    it 'keeps owners and modes' do
      run_shell('chown 65534:65534 /etc/puppetlabs/puppetserver/ca/ca_key.pem')
      result = run_bolt_task('ovadm::backup_create')
      expect(result.exit_code).to eq(0)
      line = verbose_listing(result.result['archive']).lines.find { |l| l.end_with?("ca/ca_key.pem\n") }
      expect(line).to match(/^-rw-r-----/)
      expect(line).to match(%r{ (nobody|nogroup|65534)/})
    end

    it 'warns about an eyaml key on the host that the archive does not hold, and not once it does' do
      # A key the host does not have (a feature branch's hiera.yaml) is no gap.
      result = run_bolt_task('ovadm::backup_create')
      expect(result.result['warnings']).to eq([])

      run_shell('install -d -m 0750 /etc/puppetlabs-eyaml && echo EYAML > /etc/puppetlabs-eyaml/private_key.pkcs7.pem')
      result = run_bolt_task('ovadm::backup_create')
      expect(result.result['warnings']).to eq(['eyaml private key /etc/puppetlabs-eyaml/private_key.pkcs7.pem (named in /etc/puppetlabs/code/environments/production/hiera.yaml) is not in the archive; add it to extra_paths'])

      result = run_bolt_task('ovadm::backup_create', { 'extra_paths' => '/etc/puppetlabs-eyaml' })
      expect(result.result['warnings']).to eq([])
      expect(listing(result.result['archive'])).to include(a_string_ending_with('/files/etc/puppetlabs-eyaml/private_key.pkcs7.pem'))
    end
  end

  context 'with items switched off' do
    it 'leaves the CA and certificates out with ca off' do
      result = run_bolt_task('ovadm::backup_create', { 'ca' => false })
      expect(result.exit_code).to eq(0)
      members = listing(result.result['archive'])
      expect(members.grep(%r{/puppetserver/ca/})).to be_empty
      expect(members.grep(%r{/puppet/ssl/})).to be_empty
      expect(members.grep(%r{/puppetdb/ssl/})).to be_empty
      expect(members).to include(a_string_ending_with('/files/etc/puppetlabs/puppet/puppet.conf'))
    end

    it 'takes only the CA and certificates with config and code off' do
      result = run_bolt_task('ovadm::backup_create', { 'config' => false, 'code' => false })
      expect(result.exit_code).to eq(0)
      members = listing(result.result['archive'])
      expect(members).to include(a_string_ending_with('/files/etc/puppetlabs/puppetserver/ca/ca_key.pem'),
                                 a_string_ending_with('/files/etc/puppetlabs/puppet/ssl/private_keys/host.pem'),
                                 a_string_ending_with('/files/etc/puppetlabs/puppetdb/ssl/host.pem'))
      expect(members.grep(/puppet\.conf$/)).to be_empty
      expect(members.grep(/r10k-deploy/)).to be_empty
    end

    it 'takes the code tree when asked' do
      result = run_bolt_task('ovadm::backup_create', { 'include_code_tree' => true })
      expect(result.exit_code).to eq(0)
      expect(listing(result.result['archive'])).to include(a_string_ending_with('/files/etc/puppetlabs/code/environments/production/manifests/site.pp'))
    end

    it 'refuses to run with every item off' do
      result = run_bolt_task('ovadm::backup_create', { 'ca' => false, 'config' => false, 'code' => false })
      expect(result.exit_code).to eq(1)
      expect(result.result['_error']['msg']).to include('nothing to back up')
    end
  end

  context 'with extra paths' do
    it 'includes them with their modes' do
      result = run_bolt_task('ovadm::backup_create', { 'extra_paths' => '/root/.ssh/deploy_key' })
      expect(result.exit_code).to eq(0)
      line = verbose_listing(result.result['archive']).lines.find { |l| l.end_with?("/root/.ssh/deploy_key\n") }
      expect(line).to match(/^-rw-------/)
      manifest = JSON.parse(read_from(result.result['archive'], "#{File.basename(result.result['archive'], '.tar.gz')}/ovadm/manifest.json"))
      expect(manifest['backup']['extra_paths']).to eq(['/root/.ssh/deploy_key'])
    end

    it 'fails on a path that does not exist, and on a relative one' do
      result = run_bolt_task('ovadm::backup_create', { 'extra_paths' => '/root/.ssh/deploy_key,/no/such/key' })
      expect(result.exit_code).to eq(1)
      expect(result.result['_error']['msg']).to eq("extra path '/no/such/key' does not exist")
      expect(run_shell("ls -A #{destination} 2>/dev/null")['stdout'].strip).to eq('')

      result = run_bolt_task('ovadm::backup_create', { 'extra_paths' => 'root/.ssh/deploy_key' })
      expect(result.exit_code).to eq(1)
      expect(result.result['_error']['msg']).to eq("extra path 'root/.ssh/deploy_key' is not absolute")
    end
  end

  it 'copes with stop_services on a host without systemd' do
    result = run_bolt_task('ovadm::backup_create', { 'stop_services' => true })
    expect(result.exit_code).to eq(0)
    expect(result.result['services_stopped']).to eq([])
  end

  it 'stops the running services for the copy, starts them again, and records which' do
    # A stand-in systemctl: puppetserver is active, puppetdb is not; calls are logged.
    run_shell(<<~SH)
      cat > /usr/local/sbin/systemctl <<'FAKE'
      #!/bin/bash
      echo "$*" >> /tmp/systemctl.log
      case "$1 $3" in "is-active puppetserver") exit 0 ;; "is-active puppetdb") exit 3 ;; esac
      exit 0
      FAKE
      chmod 0755 /usr/local/sbin/systemctl; rm -f /tmp/systemctl.log
    SH
    result = run_bolt_task('ovadm::backup_create', { 'stop_services' => true })
    run_shell('rm -f /usr/local/sbin/systemctl')
    expect(result.exit_code).to eq(0)
    expect(result.result['services_stopped']).to eq(['puppetserver'])
    manifest = JSON.parse(read_from(result.result['archive'], "#{File.basename(result.result['archive'], '.tar.gz')}/ovadm/manifest.json"))
    expect(manifest['backup']['services_stopped']).to eq(['puppetserver'])
    expect(run_shell('cat /tmp/systemctl.log')['stdout'].lines.map(&:strip)).to eq(
      ['is-active --quiet puppetserver', 'stop puppetserver', 'is-active --quiet puppetdb', 'start puppetserver']
    )
  end

  it 'fails on age_recipient when age is not installed' do
    result = run_bolt_task('ovadm::backup_create', { 'age_recipient' => 'age1qqqqqqqq' })
    expect(result.exit_code).to eq(1)
    expect(result.result['_error']['msg']).to include('age is not installed')
  end

  it 'leaves nothing behind in the destination but archives' do
    run_bolt_task('ovadm::backup_create')
    run_bolt_task('ovadm::backup_create', { 'extra_paths' => '/no/such' })
    expect(run_shell("ls -A #{destination}")['stdout'].split.grep_v(/^openvox-backup-.*\.tar\.gz$/)).to be_empty
  end
end
