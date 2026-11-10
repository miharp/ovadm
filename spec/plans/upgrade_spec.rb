# frozen_string_literal: true

require_relative 'spec_helper'

describe 'ovadm::upgrade' do
  let(:server)         { 'ovox-server.example.com' }
  let(:compiler)       { 'ovox-compiler01.example.com' }
  let(:server_version) { '8.13.0' }

  let(:lock) { 'ovadm upgrade to 8.13.0 in progress' }
  let(:disabled) { { 'status' => 'disabled', 'disabled_here' => true, 'message' => lock, 'waited' => 0 } }
  let(:enabled)  { { 'status' => 'enabled', 'message' => lock } }

  before(:each) do
    execute_no_plan
    allow_task('ovadm::agent_disable').always_return(disabled)
    allow_task('ovadm::agent_enable').always_return(enabled)
  end

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

  context 'the agents' do
    before(:each) do
      allow_plan('ovadm::subplans::precheck')
      allow_plan('ovadm::backup').always_return(backup_result)
      allow_plan('ovadm::subplans::upgrade_server')
      allow_plan('ovadm::subplans::upgrade_compilers')
    end

    let(:params) { { 'server_host' => server, 'ovox_server_version' => server_version, 'compiler_hosts' => compiler } }

    it 'disables the agent on the server and every compiler, and enables them again at the end' do
      expect_task('ovadm::agent_disable')
        .with_targets([server, compiler])
        .with_params('message' => lock, 'reclaim' => 'ovadm upgrade', '_catch_errors' => true)
        .be_called_times(1).always_return(disabled)
      expect_task('ovadm::agent_enable')
        .with_targets([server, compiler])
        .with_params('only_message' => 'ovadm upgrade', '_catch_errors' => true)
        .be_called_times(1).always_return(enabled)

      result = run_plan('ovadm::upgrade', params)
      expect(result).to be_ok
      expect(result.value['agents_held']).to eq([server, compiler])
    end

    it 'names no version in the message when upgrading from package_url' do
      expect_task('ovadm::agent_disable')
        .with_params('message' => 'ovadm upgrade in progress', 'reclaim' => 'ovadm upgrade', '_catch_errors' => true)
        .be_called_times(1).always_return(disabled)

      result = run_plan('ovadm::upgrade', { 'server_host' => server, 'package_url' => 'https://s3.example.com/openvox-server-9.0.0.rpm', 'ovox_major' => 9 })
      expect(result).to be_ok
    end

    it 'leaves an agent the operator had disabled as it was, and says so' do
      allow_task('ovadm::agent_disable').return_for_targets(
        server   => disabled,
        compiler => { 'status' => 'already_disabled', 'disabled_here' => false, 'message' => 'maintenance, ask Sam', 'waited' => 0 },
      )
      expect_task('ovadm::agent_enable').with_targets([server]).be_called_times(1).always_return(enabled)
      expect_out_message.with_params("#{compiler}: the agent was already disabled (maintenance, ask Sam); it stays disabled after the upgrade.")

      result = run_plan('ovadm::upgrade', params)
      expect(result).to be_ok
      expect(result.value['agents_held']).to eq([server])
    end

    it 'enables an agent an interrupted run of the plan left disabled' do
      allow_task('ovadm::agent_disable').always_return('status' => 'reclaimed', 'disabled_here' => true, 'message' => lock, 'waited' => 0)
      expect_task('ovadm::agent_enable').with_targets([server, compiler]).be_called_times(1).always_return(enabled)

      expect(run_plan('ovadm::upgrade', params)).to be_ok
    end

    it 'runs no enable task when it disabled nothing' do
      allow_task('ovadm::agent_disable').always_return('status' => 'already_disabled', 'disabled_here' => false, 'message' => 'frozen', 'waited' => 0)
      expect_task('ovadm::agent_enable').not_be_called

      result = run_plan('ovadm::upgrade', params)
      expect(result).to be_ok
      expect(result.value['agents_held']).to eq([])
    end

    it 'upgrades nothing when an agent cannot be disabled, and enables the ones it had disabled' do
      allow_task('ovadm::agent_disable').error_with('msg' => 'an agent run (pid 4242) has not finished after 300 s', 'kind' => 'ovadm/agent')
      expect_plan('ovadm::backup').not_be_called
      expect_plan('ovadm::subplans::upgrade_server').not_be_called
      expect_plan('ovadm::subplans::upgrade_compilers').not_be_called
      expect_task('ovadm::agent_enable').not_be_called

      result = run_plan('ovadm::upgrade', params)
      expect(result).not_to be_ok
      expect(result.value.kind).to eq('ovadm/upgrade')
      expect(result.value.msg).to match(/Could not disable the agent, so nothing was upgraded\. .*#{Regexp.escape(server)}: an agent run \(pid 4242\)/)
    end

    it 'enables the agents again when the upgrade fails, then fails with the upgrade error' do
      expect_plan('ovadm::subplans::upgrade_server').error_with('msg' => 'dnf could not install openvox-server', 'kind' => 'ovadm/install')
      expect_plan('ovadm::subplans::upgrade_compilers').not_be_called
      expect_task('ovadm::agent_enable').with_targets([server, compiler]).be_called_times(1).always_return(enabled)
      expect_out_message.with_params('The upgrade failed. The agents this plan disabled are enabled again, unless a line above names a host where that failed.')

      result = run_plan('ovadm::upgrade', params)
      expect(result).not_to be_ok
      expect(result.value.msg).to match(/dnf could not install openvox-server/)
    end

    it 'enables the agents again when the backup fails' do
      allow_plan('ovadm::backup').error_with('msg' => 'no space under /var/backups/openvox', 'kind' => 'ovadm/backup')
      expect_plan('ovadm::subplans::upgrade_server').not_be_called
      expect_task('ovadm::agent_enable').be_called_times(1).always_return(enabled)

      result = run_plan('ovadm::upgrade', params)
      expect(result).not_to be_ok
      expect(result.value.msg).to match(/no space/)
    end

    it 'names the hosts where the agent could not be enabled again' do
      allow_task('ovadm::agent_enable').error_with('msg' => 'puppet agent --enable failed; run it on the host', 'kind' => 'ovadm/agent')
      expect_out_message.with_params("Could not enable the agent again on #{server}, #{compiler}. Run 'puppet agent --enable' there.")

      expect(run_plan('ovadm::upgrade', params)).to be_ok
    end

    it 'leaves alone an agent someone disabled again during the upgrade' do
      allow_task('ovadm::agent_enable').return_for_targets(
        server   => enabled,
        compiler => { 'status' => 'left_disabled', 'message' => 'do not touch' },
      )
      expect_out_message.with_params("#{compiler}: the agent was disabled again during the upgrade (do not touch); it stays disabled.")

      expect(run_plan('ovadm::upgrade', params)).to be_ok
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
