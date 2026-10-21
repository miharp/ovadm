# frozen_string_literal: true

require_relative 'spec_helper'

describe 'ovadm::backup' do
  let(:server) { 'ovox.example.com' }
  let(:archive) { '/var/backups/openvox/openvox-backup-ovox.example.com-20261021T180000Z.tar.gz' }

  let(:created) do
    {
      'status' => 'created', 'archive' => archive, 'size_bytes' => 40_960, 'files' => 12,
      'certname' => server, 'created' => '2026-10-21T18:00:00Z', 'ca_serial_moved' => false,
      'services_stopped' => [], 'warnings' => []
    }
  end

  let(:verified) do
    {
      'status' => 'ok', 'archive' => archive, 'name' => File.basename(archive, '.tar.gz'),
      'created' => '2026-10-21T18:00:00Z', 'certname' => server, 'files' => 12,
      'checksums' => { 'checked' => 15, 'failed' => [] },
      'host' => { 'certname' => server, 'certname_matches' => true, 'packages' => {} },
      'problems' => [], 'warnings' => []
    }
  end

  let(:default_params) do
    {
      'destination' => '/var/backups/openvox', 'ca' => true, 'config' => true, 'code' => true,
      'include_code_tree' => false, 'stop_services' => false,
      'ovadm_version' => ovadm_version
    }
  end

  let(:ovadm_version) { JSON.parse(File.read(File.expand_path('../../metadata.json', __dir__)))['version'] }

  it 'creates the archive with everything on, then verifies it' do
    expect_task('ovadm::backup_create').with_params(default_params).always_return(created)
    expect_task('ovadm::backup_verify').with_params('archive' => archive).always_return(verified)
    expect_out_message.with_params("#{server}: #{archive} (0.0 MB, 12 files)")
    expect_out_message.with_params("#{server}: 15 checksums checked, ok")

    result = run_plan('ovadm::backup', { 'server_host' => server })
    expect(result).to be_ok
    expect(result.value['backup'].first.value).to eq(created)
    expect(result.value['verify']).to eq(server => verified)
  end

  it 'passes the options through: items off, the code tree, extra paths, services, age' do
    expect_task('ovadm::backup_create').with_params(default_params.merge(
      'destination' => '/srv/backup', 'ca' => false, 'code' => true, 'include_code_tree' => true,
      'extra_paths' => '/root/.ssh,/etc/systemd/system/r10k-deploy.timer', 'stop_services' => true,
      'age_recipient' => 'age1example'
    )).always_return(created)
    allow_task('ovadm::backup_verify').always_return(verified)

    result = run_plan('ovadm::backup', {
      'server_host' => server, 'destination' => '/srv/backup', 'backup' => { 'ca' => false },
      'include_code_tree' => true, 'extra_paths' => ['/root/.ssh', '/etc/systemd/system/r10k-deploy.timer'],
      'stop_services' => true, 'age_recipient' => 'age1example'
    })
    expect(result).to be_ok
  end

  it 'skips verification for an encrypted archive, and says so' do
    allow_task('ovadm::backup_create').always_return(created.merge('archive' => "#{archive}.age"))
    expect_task('ovadm::backup_verify').not_be_called
    expect_out_message.with_params('Not verified: the archive is encrypted to age1example. Run ovadm::backup_verify with age_identity where the identity is.')

    result = run_plan('ovadm::backup', { 'server_host' => server, 'age_recipient' => 'age1example' })
    expect(result).to be_ok
    expect(result.value['verify']).to eq({})
  end

  it 'skips verification when asked' do
    allow_task('ovadm::backup_create').always_return(created)
    expect_task('ovadm::backup_verify').not_be_called

    result = run_plan('ovadm::backup', { 'server_host' => server, 'verify' => false })
    expect(result).to be_ok
    expect(result.value['verify']).to eq({})
  end

  it 'refuses to run with every item off' do
    expect_task('ovadm::backup_create').not_be_called

    result = run_plan('ovadm::backup', { 'server_host' => server, 'backup' => { 'ca' => false, 'config' => false, 'code' => false } })
    expect(result).not_to be_ok
    expect(result.value.msg).to include('Nothing to back up')
  end

  it 'prints the warnings the task returns, and that the CA moved' do
    allow_task('ovadm::backup_create').always_return(created.merge(
      'ca_serial_moved' => true,
      'warnings' => ['eyaml private key /etc/puppetlabs/eyaml/keys/private_key.pkcs7.pem (named in /etc/puppetlabs/code/environments/production/hiera.yaml) is not in the archive; add it to extra_paths']
    ))
    allow_task('ovadm::backup_verify').always_return(verified)
    expect_out_message.with_params("WARNING #{server}: a certificate was signed or revoked while the CA directory was copied; take the backup again")
    expect_out_message.with_params("WARNING #{server}: eyaml private key /etc/puppetlabs/eyaml/keys/private_key.pkcs7.pem (named in /etc/puppetlabs/code/environments/production/hiera.yaml) is not in the archive; add it to extra_paths")

    expect(run_plan('ovadm::backup', { 'server_host' => server })).to be_ok
  end

  it 'fails when verification finds a problem, after printing it' do
    allow_task('ovadm::backup_create').always_return(created)
    allow_task('ovadm::backup_verify').always_return(verified.merge(
      'status' => 'failed', 'checksums' => { 'checked' => 15, 'failed' => ['files/etc/puppetlabs/puppetserver/ca/ca_key.pem'] },
      'problems' => ['1 file(s) do not match their checksum: files/etc/puppetlabs/puppetserver/ca/ca_key.pem']
    ))
    expect_out_message.with_params("ERROR #{server}: 1 file(s) do not match their checksum: files/etc/puppetlabs/puppetserver/ca/ca_key.pem")

    result = run_plan('ovadm::backup', { 'server_host' => server })
    expect(result).not_to be_ok
    expect(result.value.msg).to eq("Backup verification failed on #{server}")
  end
end
