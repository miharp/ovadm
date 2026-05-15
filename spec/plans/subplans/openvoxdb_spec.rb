# frozen_string_literal: true

require_relative '../spec_helper'

describe 'ovadm::subplans::openvoxdb' do
  let(:server) { 'ovox-server.example.com' }
  let(:pdb)    { 'ovox-pdb.example.com' }

  before(:each) do
    execute_no_plan
    allow_command('hostname -f').always_return('stdout' => "#{server}\n", 'stderr' => '')
    allow_command('systemctl enable --now puppetdb').always_return('stdout' => '', 'stderr' => '')
    allow_command('systemctl restart puppetserver').always_return('stdout' => '', 'stderr' => '')
    allow_task('ovadm::install_openvoxdb').always_return('status' => 'success', 'version' => '8.26.2')
    allow_task('ovadm::configure_openvoxdb').always_return('status' => 'success')
    allow_task('ovadm::wait_until_openvoxdb_ready').always_return('status' => 'ready', 'elapsed_seconds' => 5)
    allow_task('ovadm::configure_server_for_openvoxdb').always_return('status' => 'success')
    allow_task('ovadm::wait_until_service_ready').always_return('status' => 'ready', 'elapsed_seconds' => 5)
  end

  context 'co-located (co_located: true)' do
    it 'installs packages, configures db, starts service, and wires the server' do
      expect_task('ovadm::install_openvoxdb').be_called_times(1)
      expect_task('ovadm::configure_openvoxdb').be_called_times(1)
      expect_task('ovadm::configure_server_for_openvoxdb').be_called_times(1)
      expect_task('ovadm::wait_until_openvoxdb_ready').be_called_times(1)
      expect_task('ovadm::wait_until_service_ready').be_called_times(1)

      result = run_plan('ovadm::subplans::openvoxdb', {
        'server_host'   => server,
        'puppetdb_host' => server,
        'db_password'   => 's3cret',
        'co_located'    => true
      })
      expect(result).to be_ok
    end

    it 'skips cert setup and agent install' do
      allow_task('ovadm::configure_repo').not_be_called
      allow_task('ovadm::install_agent').not_be_called
      allow_task('ovadm::set_csr_attributes').not_be_called
      allow_task('ovadm::sign_csr').not_be_called

      run_plan('ovadm::subplans::openvoxdb', {
        'server_host'   => server,
        'puppetdb_host' => server,
        'db_password'   => 's3cret',
        'co_located'    => true
      })
    end
  end

  context 'separate node (co_located: false)' do
    before(:each) do
      allow_task('ovadm::configure_repo').always_return('status' => 'success')
      allow_task('ovadm::install_agent').always_return('status' => 'success', 'version' => '8.26.2')
      allow_task('ovadm::configure_puppet_conf').always_return('status' => 'success')
      allow_task('ovadm::set_csr_attributes').always_return('status' => 'success')
      allow_task('ovadm::agent_runonce').always_return('status' => 'success')
      allow_task('ovadm::sign_csr').always_return('status' => 'success')
    end

    it 'bootstraps the PuppetDB node with a cert before installing' do
      expect_task('ovadm::configure_repo').be_called_times(1)
      expect_task('ovadm::install_agent').be_called_times(1)
      expect_task('ovadm::configure_puppet_conf').be_called_times(1)
      expect_task('ovadm::set_csr_attributes').be_called_times(1)
      expect_task('ovadm::sign_csr').be_called_times(1)
      expect_task('ovadm::install_openvoxdb').be_called_times(2)

      result = run_plan('ovadm::subplans::openvoxdb', {
        'server_host'   => server,
        'puppetdb_host' => pdb,
        'db_password'   => 's3cret',
        'co_located'    => false
      })
      expect(result).to be_ok
    end

    it 'installs openvoxdb twice: once on pdb node, once (termini only) on server' do
      expect_task('ovadm::install_openvoxdb').be_called_times(2)

      run_plan('ovadm::subplans::openvoxdb', {
        'server_host'   => server,
        'puppetdb_host' => pdb,
        'db_password'   => 's3cret',
        'co_located'    => false
      })
    end
  end
end
