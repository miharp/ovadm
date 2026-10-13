# frozen_string_literal: true

require_relative 'spec_helper'

describe 'ovadm::add_agent' do
  let(:server)  { 'ovox-server.example.com' }
  let(:agent01) { 'agent01.example.com' }
  let(:agent02) { 'agent02.example.com' }
  let(:params)  { { 'server_host' => server, 'agent_hosts' => [agent01, agent02] } }

  def package_params(overrides = {})
    {
      'agent_hosts'  => [agent01, agent02],
      'server'       => server,
      'ca_server'    => server,
      'ovox_major'   => 8,
      'ovox_version' => nil,
      'apt_base_url' => nil,
      'yum_base_url' => nil,
      'environment'  => nil,
    }.merge(overrides)
  end

  def server_runs(version, package = 'openvox-server')
    expect_task('ovadm::get_version').with_targets(server).always_return('version' => version, 'package' => package)
  end

  before(:each) do
    execute_no_plan
    allow_command('hostname -f').always_return('stdout' => "#{server}\n", 'stderr' => '')
    allow_plan('ovadm::subplans::precheck')
  end

  it 'prechecks the agents as agents, packages them, then enrols them' do
    server_runs('8.17.0-1.el10')
    expect_plan('ovadm::subplans::precheck')
      .with_params('server_host' => [agent01, agent02], 'role' => 'agent')
      .be_called_times(1)
    expect_plan('ovadm::subplans::agent_package')
      .with_params(package_params)
      .always_return('ok' => [agent01, agent02], 'failed' => {})
    expect_plan('ovadm::subplans::agent_enroll')
      .with_params('agent_hosts' => [agent01, agent02], 'server_host' => server, 'environment' => nil)
      .always_return('ok' => [agent01, agent02], 'failed' => {})

    result = run_plan('ovadm::add_agent', params)
    expect(result).to be_ok
    expect(result.value).to eq('ok' => [agent01, agent02])
  end

  it 'follows the server major when no version is given' do
    server_runs('9.0.1-1.el10')
    expect_plan('ovadm::subplans::agent_package')
      .with_params(package_params('ovox_major' => 9))
      .always_return('ok' => [], 'failed' => {})
    allow_plan('ovadm::subplans::agent_enroll').always_return('ok' => [], 'failed' => {})

    expect(run_plan('ovadm::add_agent', params)).to be_ok
  end

  it 'stops when the server is still on Puppet Server' do
    server_runs('7.17.3-1jammy', 'puppetserver')
    expect_plan('ovadm::subplans::agent_package').not_be_called

    result = run_plan('ovadm::add_agent', params)
    expect(result).not_to be_ok
    expect(result.value.message).to match(/has puppetserver 7\.17\.3-1jammy.*ovadm::upgrade first, or pass ovox_version/)
  end

  it 'installs the version given without asking the server' do
    expect_task('ovadm::get_version').not_be_called
    expect_plan('ovadm::subplans::agent_package')
      .with_params(package_params('ovox_major' => 9, 'ovox_version' => '9.1.0'))
      .always_return('ok' => [], 'failed' => {})
    allow_plan('ovadm::subplans::agent_enroll').always_return('ok' => [], 'failed' => {})

    expect(run_plan('ovadm::add_agent', params.merge('ovox_version' => '9.1.0'))).to be_ok
  end

  it 'points the agents at agent_server, with the server as CA, and hands the environment on' do
    server_runs('8.17.0-1.el10')
    expect_plan('ovadm::subplans::agent_package')
      .with_params(package_params(
        'server'       => 'compiler01.example.com',
        'apt_base_url' => 'https://mirror/apt',
        'yum_base_url' => 'https://mirror/yum',
        'environment'  => 'demo',
      ))
      .always_return('ok' => [agent01, agent02], 'failed' => {})
    expect_plan('ovadm::subplans::agent_enroll')
      .with_params('agent_hosts' => [agent01, agent02], 'server_host' => server, 'environment' => 'demo')
      .always_return('ok' => [agent01, agent02], 'failed' => {})

    result = run_plan('ovadm::add_agent', params.merge(
      'agent_server' => 'compiler01.example.com',
      'apt_base_url' => 'https://mirror/apt',
      'yum_base_url' => 'https://mirror/yum',
      'environment'  => 'demo',
    ))
    expect(result).to be_ok
  end

  it 'enrols the hosts that got through and fails with the ones that did not' do
    server_runs('8.17.0-1.el10')
    expect_plan('ovadm::subplans::agent_package')
      .always_return('ok' => [agent01], 'failed' => { agent02 => 'No package openvox-agent available' })
    expect_plan('ovadm::subplans::agent_enroll')
      .with_params('agent_hosts' => [agent01], 'server_host' => server, 'environment' => nil)
      .always_return('ok' => [agent01], 'failed' => {})

    result = run_plan('ovadm::add_agent', params)
    expect(result).not_to be_ok
    expect(result.value.message).to match(/failed on 1 of 2 agent/)
    expect(result.value.message).to match(/#{agent02}: No package openvox-agent available/)
  end
end
