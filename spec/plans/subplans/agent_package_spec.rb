# frozen_string_literal: true

require_relative '../spec_helper'

describe 'ovadm::subplans::agent_package' do
  let(:server)  { 'ovox-server.example.com' }
  let(:agent01) { 'agent01.example.com' }
  let(:agent02) { 'agent02.example.com' }
  let(:params) do
    { 'agent_hosts' => [agent01, agent02], 'server' => server, 'ca_server' => server, 'ovox_major' => 8 }
  end

  before(:each) do
    allow_task('ovadm::configure_repo').always_return('status' => 'success')
    allow_task('ovadm::install_agent').always_return('status' => 'success', 'version' => '8.30.0-1.el9')
    allow_task('ovadm::configure_puppet_conf').always_return('status' => 'success')
  end

  it 'configures the repo, installs the agent and writes puppet.conf on every agent' do
    expect_task('ovadm::configure_repo').with_targets([agent01, agent02]).with_params('ovox_major' => 8, '_catch_errors' => true).be_called_times(1)
    expect_task('ovadm::install_agent').with_targets([agent01, agent02]).with_params('_catch_errors' => true).be_called_times(1)
    expect_task('ovadm::configure_puppet_conf')
      .with_targets([agent01, agent02])
      .with_params('server' => server, 'ca_server' => server, '_catch_errors' => true)
      .be_called_times(1)

    result = run_plan('ovadm::subplans::agent_package', params)
    expect(result).to be_ok
    expect(result.value['ok']).to eq([agent01, agent02])
    expect(result.value['failed']).to eq({})
  end

  it 'passes the version, the mirrors and the environment through' do
    expect_task('ovadm::configure_repo')
      .with_params('ovox_major' => 9, 'apt_base_url' => 'https://mirror/apt', 'yum_base_url' => 'https://mirror/yum', '_catch_errors' => true)
    expect_task('ovadm::install_agent').with_params('version' => '9.1.0', '_catch_errors' => true)
    expect_task('ovadm::configure_puppet_conf')
      .with_params('server' => 'compiler01.example.com', 'ca_server' => server, 'environment' => 'demo', '_catch_errors' => true)

    result = run_plan('ovadm::subplans::agent_package', params.merge(
      'server'       => 'compiler01.example.com',
      'ovox_major'   => 9,
      'ovox_version' => '9.1.0',
      'apt_base_url' => 'https://mirror/apt',
      'yum_base_url' => 'https://mirror/yum',
      'environment'  => 'demo',
    ))
    expect(result).to be_ok
  end

  it 'leaves a host that failed a step out of the following ones and reports it' do
    expect_task('ovadm::install_agent')
      .with_targets([agent01, agent02])
      .return_for_targets(agent01 => { 'status' => 'success', 'version' => '8.30.0' })
      .error_with('msg' => 'No package openvox-agent available', 'kind' => 'puppetlabs.tasks/task-error')
    expect_task('ovadm::configure_puppet_conf').with_targets([agent01]).be_called_times(1)

    result = run_plan('ovadm::subplans::agent_package', params)
    expect(result).to be_ok
    expect(result.value['ok']).to eq([agent01])
    expect(result.value['failed']).to eq(agent02 => 'No package openvox-agent available')
  end
end
