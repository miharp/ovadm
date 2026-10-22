# frozen_string_literal: true

require_relative 'spec_helper'

describe 'ovadm::upgrade' do
  let(:server)         { 'ovox-server.example.com' }
  let(:compiler)       { 'ovox-compiler01.example.com' }
  let(:server_version) { '8.13.0' }

  before(:each) { execute_no_plan }

  let(:archive) { "/var/backups/openvox/openvox-backup-#{server}-20261022T120000Z.tar.gz" }
  let(:backup_result) { { 'backup' => [], 'archives' => { server => archive }, 'verify' => {} } }

  context 'Standard topology (no compiler_hosts)' do
    it 'runs precheck, takes a backup of the server, then upgrade_server' do
      expect_plan('ovadm::subplans::precheck').be_called_times(1)
      expect_plan('ovadm::backup')
        .with_params('server_host' => server, 'destination' => '/var/backups/openvox', 'extra_paths' => [])
        .be_called_times(1).always_return(backup_result)
      expect_plan('ovadm::subplans::upgrade_server').be_called_times(1)
      allow_plan('ovadm::subplans::upgrade_compilers').not_be_called
      expect_out_message.with_params("Pre-upgrade backup of #{server}: #{archive}. Copy it off the host; it is the way back if this upgrade goes wrong.")

      result = run_plan('ovadm::upgrade', {
        'server_host'         => server,
        'ovox_server_version' => server_version
      })
      expect(result).to be_ok
      expect(result.value['backup']).to eq(server => archive)
    end

    it 'passes the backup destination and extra paths through' do
      allow_plan('ovadm::subplans::precheck')
      expect_plan('ovadm::backup')
        .with_params('server_host' => server, 'destination' => '/srv/backup', 'extra_paths' => ['/root/.ssh'])
        .be_called_times(1).always_return(backup_result)
      allow_plan('ovadm::subplans::upgrade_server')

      result = run_plan('ovadm::upgrade', {
        'server_host' => server, 'ovox_server_version' => server_version,
        'backup_destination' => '/srv/backup', 'backup_extra_paths' => ['/root/.ssh']
      })
      expect(result).to be_ok
    end

    it 'takes no backup with skip_backup' do
      allow_plan('ovadm::subplans::precheck')
      expect_plan('ovadm::backup').not_be_called
      allow_plan('ovadm::subplans::upgrade_server')

      result = run_plan('ovadm::upgrade', { 'server_host' => server, 'ovox_server_version' => server_version, 'skip_backup' => true })
      expect(result).to be_ok
      expect(result.value['backup']).to eq({})
    end
  end

  context 'Large topology (with compiler_hosts)' do
    it 'also runs upgrade_compilers' do
      allow_plan('ovadm::backup').always_return(backup_result)
      expect_plan('ovadm::subplans::precheck').be_called_times(1)
      expect_plan('ovadm::subplans::upgrade_server').be_called_times(1)
      expect_plan('ovadm::subplans::upgrade_compilers').be_called_times(1)

      result = run_plan('ovadm::upgrade', {
        'server_host'         => server,
        'ovox_server_version' => server_version,
        'compiler_hosts'      => compiler
      })
      expect(result).to be_ok
    end
  end

  context 'target major version' do
    before(:each) { allow_plan('ovadm::backup').always_return(backup_result) }

    it 'prechecks in upgrade mode for the target major, so the Java check fits it' do
      expect_plan('ovadm::subplans::precheck')
        .with_params('server_host' => server, 'upgrade' => true, 'ovox_major' => 9)
        .be_called_times(1)
      allow_plan('ovadm::subplans::upgrade_server')

      result = run_plan('ovadm::upgrade', { 'server_host' => server, 'ovox_server_version' => '9.0.0' })
      expect(result).to be_ok
    end

    it 'takes the major version from ovox_server_version' do
      allow_plan('ovadm::subplans::precheck')
      expect_plan('ovadm::subplans::upgrade_server')
        .with_params(
          'server_host'         => server,
          'ovox_server_version' => '9.0.0',
          'package_url'         => nil,
          'ovox_major'          => 9,
          'apt_base_url'        => nil,
          'yum_base_url'        => nil,
        )
        .be_called_times(1)

      result = run_plan('ovadm::upgrade', { 'server_host' => server, 'ovox_server_version' => '9.0.0' })
      expect(result).to be_ok
    end

    it 'takes ovox_major when upgrading from package_url alone' do
      pkg_url = 'https://s3.example.com/openvox-server-9.0.0.rpm'
      allow_plan('ovadm::subplans::precheck')
      expect_plan('ovadm::subplans::upgrade_server')
        .with_params(
          'server_host'         => server,
          'ovox_server_version' => nil,
          'package_url'         => pkg_url,
          'ovox_major'          => 9,
          'apt_base_url'        => nil,
          'yum_base_url'        => nil,
        )
        .be_called_times(1)

      result = run_plan('ovadm::upgrade', { 'server_host' => server, 'package_url' => pkg_url, 'ovox_major' => 9 })
      expect(result).to be_ok
    end

    it 'fails when ovox_major and ovox_server_version disagree' do
      result = run_plan('ovadm::upgrade', {
        'server_host'         => server,
        'ovox_server_version' => '8.16.0',
        'ovox_major'          => 9
      })
      expect(result).not_to be_ok
      expect(result.value.msg).to match(/does not match/)
    end
  end
end
