# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'ovadm::backup_verify task' do
  let(:destination) { '/var/backups/openvox' }

  # A small primary, as backup_create_spec lays one out.
  before(:context) do
    run_shell(<<~SH)
      set -e
      rm -rf /etc/puppetlabs #{'/var/backups/openvox'}
      install -d -m 0750 /etc/puppetlabs/puppetserver/ca/signed
      echo CAKEY > /etc/puppetlabs/puppetserver/ca/ca_key.pem
      echo CACRT > /etc/puppetlabs/puppetserver/ca/ca_crt.pem
      printf '0x0005\\n' > /etc/puppetlabs/puppetserver/ca/serial
      install -d /etc/puppetlabs/puppet/ssl/private_keys /etc/puppetlabs/puppetserver/conf.d
      echo HOSTKEY > /etc/puppetlabs/puppet/ssl/private_keys/host.pem
      printf '[main]\\ncertname = host\\n' > /etc/puppetlabs/puppet/puppet.conf
      echo 'webserver: {}' > /etc/puppetlabs/puppetserver/conf.d/webserver.conf
    SH
  end

  def create
    result = run_bolt_task('ovadm::backup_create')
    raise "backup_create failed: #{result.result}" unless result.exit_code.zero?

    result.result['archive']
  end

  # Unpack, run the given shell in the archive's top directory, repack.
  def repack(archive, shell, resum: false)
    name = File.basename(archive, '.tar.gz')
    run_shell(<<~SH)
      set -e
      rm -rf /tmp/repack && mkdir /tmp/repack
      tar -xzf #{archive} -C /tmp/repack
      cd /tmp/repack/#{name}
      #{shell}
      #{resum ? 'find files ovadm -type f ! -path ovadm/SHA256SUMS -print0 | LC_ALL=C sort -z | xargs -0 sha256sum > ovadm/SHA256SUMS' : ''}
      cd /tmp/repack && tar -czf #{archive} #{name}
    SH
  end

  it 'passes an archive as backup_create wrote it, and reports what it holds' do
    archive = create
    result = run_bolt_task('ovadm::backup_verify', { 'archive' => archive })
    expect(result.exit_code).to eq(0)
    data = result.result
    expect(data['status']).to eq('ok')
    expect(data['problems']).to eq([])
    expect(data['name']).to eq(File.basename(archive, '.tar.gz'))
    members = run_shell("tar -tzf #{archive}")['stdout'].lines.map(&:strip)
    expect(data['files']).to eq(members.count { |m| m.include?('/files/') && !m.end_with?('/') })
    expect(data['checksums']['checked']).to eq(data['files'] + 2)
    expect(data['checksums']['failed']).to eq([])
    expect(data['host']['certname_matches']).to be(true)
    expect(data['host']['certname']).to eq(data['certname'])
    expect(data['host']['packages']).to include('openvox-server' => { 'archive' => nil, 'host' => nil })
    expect(data['warnings']).to eq([])
    expect(run_shell("ls -A #{destination}")['stdout'].split).to eq([File.basename(archive)])
  end

  it 'fails on a file that changed, naming it' do
    archive = create
    repack(archive, 'echo TAMPERED > files/etc/puppetlabs/puppetserver/ca/ca_key.pem')
    data = run_bolt_task('ovadm::backup_verify', { 'archive' => archive }).result
    expect(data['status']).to eq('failed')
    expect(data['checksums']['failed']).to eq(['files/etc/puppetlabs/puppetserver/ca/ca_key.pem'])
    expect(data['problems']).to eq(['1 file(s) do not match their checksum: files/etc/puppetlabs/puppetserver/ca/ca_key.pem'])
  end

  it 'fails on a file that is missing, and on one that is not listed' do
    archive = create
    repack(archive, 'rm files/etc/puppetlabs/puppet/puppet.conf; echo EXTRA > files/etc/puppetlabs/extra.conf')
    data = run_bolt_task('ovadm::backup_verify', { 'archive' => archive }).result
    expect(data['status']).to eq('failed')
    expect(data['checksums']['failed']).to eq(['files/etc/puppetlabs/puppet/puppet.conf'])
    expect(data['problems']).to include('file(s) in the archive without a checksum: files/etc/puppetlabs/extra.conf')
  end

  it 'fails when the archive is from another host, unless check_host is off' do
    archive = create
    repack(archive, %q(sed -i 's/^  "certname": ".*",$/  "certname": "other.example.com",/' ovadm/manifest.json), resum: true)
    data = run_bolt_task('ovadm::backup_verify', { 'archive' => archive }).result
    expect(data['status']).to eq('failed')
    expect(data['checksums']['failed']).to eq([])
    expect(data['host']['certname_matches']).to be(false)
    expect(data['problems']).to eq(["the archive is from other.example.com, this host is #{data['host']['certname']}"])

    data = run_bolt_task('ovadm::backup_verify', { 'archive' => archive, 'check_host' => false }).result
    expect(data['status']).to eq('ok')
    expect(data['host']).to be_nil
  end

  it 'reports package versions that differ as warnings, not problems' do
    archive = create
    repack(archive, %q(sed -i 's/^    "openvox-server": null,$/    "openvox-server": "8.17.0-1.el10",/' ovadm/manifest.json), resum: true)
    data = run_bolt_task('ovadm::backup_verify', { 'archive' => archive }).result
    expect(data['status']).to eq('ok')
    expect(data['host']['packages']['openvox-server']).to eq('archive' => '8.17.0-1.el10', 'host' => nil)
    expect(data['warnings']).to eq(['openvox-server is 8.17.0-1.el10 in the archive and not installed on this host'])
  end

  it 'fails on an archive without a manifest' do
    archive = create
    repack(archive, 'rm ovadm/manifest.json')
    data = run_bolt_task('ovadm::backup_verify', { 'archive' => archive }).result
    expect(data['status']).to eq('failed')
    expect(data['problems']).to include('no ovadm/manifest.json in the archive')
  end

  it 'fails the task on an archive it cannot read' do
    result = run_bolt_task('ovadm::backup_verify', { 'archive' => '/var/backups/openvox/nope.tar.gz' })
    expect(result.exit_code).to eq(1)
    expect(result.result['_error']['msg']).to eq('/var/backups/openvox/nope.tar.gz does not exist')

    run_shell("echo not-a-tarball > #{destination}/bad.tar.gz")
    result = run_bolt_task('ovadm::backup_verify', { 'archive' => "#{destination}/bad.tar.gz" })
    expect(result.exit_code).to eq(1)
    expect(result.result['_error']['msg']).to eq('the archive could not be unpacked')
    expect(run_shell("ls -A #{destination}")['stdout'].split.grep(/verify/)).to be_empty
  end
end
