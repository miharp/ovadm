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
      'pp_role'      => nil,
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

  let(:read_server) { '/opt/puppetlabs/bin/puppet config print server --section agent' }

  def agents_point_at(by_agent)
    allow_command(read_server).return_for_targets(
      by_agent.transform_values { |s| { 'stdout' => "#{s}\n", 'stderr' => '' } },
    )
  end

  it 'prechecks the agents as agents, packages them, then enrolls them' do
    server_runs('8.17.0-1.el10')
    agents_point_at(agent01 => server, agent02 => server)
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
    expect(result.value).to eq('ok' => [agent01, agent02], 'servers' => { agent01 => server, agent02 => server })
  end

  it 'reports where each agent was left when the first catalog repointed one' do
    server_runs('8.17.0-1.el10')
    agents_point_at(agent01 => 'compiler01.example.com', agent02 => server)
    allow_plan('ovadm::subplans::agent_package').always_return('ok' => [agent01, agent02], 'failed' => {})
    allow_plan('ovadm::subplans::agent_enroll').always_return('ok' => [agent01, agent02], 'failed' => {})

    result = run_plan('ovadm::add_agent', params.merge('agent_server' => 'compiler01.example.com'))
    expect(result).to be_ok
    expect(result.value['servers']).to eq(agent01 => 'compiler01.example.com', agent02 => server)
  end

  it 'still succeeds when an agent\'s server setting cannot be read' do
    server_runs('8.17.0-1.el10')
    expect_command(read_server)
      .with_targets([agent01])
      .error_with('msg' => 'puppet: command not found', 'kind' => 'puppetlabs.tasks/command-error')
    allow_plan('ovadm::subplans::agent_package').always_return('ok' => [agent01], 'failed' => {})
    allow_plan('ovadm::subplans::agent_enroll').always_return('ok' => [agent01], 'failed' => {})

    result = run_plan('ovadm::add_agent', params.merge('agent_hosts' => [agent01]))
    expect(result).to be_ok
    expect(result.value['servers']).to eq(agent01 => nil)
  end

  it 'reads nothing back when no agent was enrolled' do
    server_runs('8.17.0-1.el10')
    expect_command(read_server).not_be_called
    allow_plan('ovadm::subplans::agent_package').always_return('ok' => [], 'failed' => {})
    allow_plan('ovadm::subplans::agent_enroll').always_return('ok' => [], 'failed' => {})

    result = run_plan('ovadm::add_agent', params)
    expect(result).to be_ok
    expect(result.value).to eq('ok' => [], 'servers' => {})
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
    agents_point_at(agent01 => 'compiler01.example.com', agent02 => 'compiler01.example.com')
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

  it 'hands the pp_role to agent_package' do
    server_runs('8.17.0-1.el10')
    agents_point_at(agent01 => server, agent02 => server)
    expect_plan('ovadm::subplans::agent_package')
      .with_params(package_params('pp_role' => 'role::webserver'))
      .always_return('ok' => [agent01, agent02], 'failed' => {})
    allow_plan('ovadm::subplans::agent_enroll').always_return('ok' => [agent01, agent02], 'failed' => {})

    expect(run_plan('ovadm::add_agent', params.merge('pp_role' => 'role::webserver'))).to be_ok
  end

  ['openvox_server', 'openvox_compiler'].each do |role|
    it "refuses #{role}, before anything is changed" do
      expect_task('ovadm::get_version').not_be_called
      expect_plan('ovadm::subplans::precheck').not_be_called
      expect_plan('ovadm::subplans::agent_package').not_be_called

      result = run_plan('ovadm::add_agent', params.merge('pp_role' => role))
      expect(result).not_to be_ok
      expect(result.value.message).to match(/pp_role #{role} is the role ovadm gives the server or its compilers/)
    end
  end

  it 'refuses a pp_role that would not survive as a YAML value' do
    expect_plan('ovadm::subplans::agent_package').not_be_called

    result = run_plan('ovadm::add_agent', params.merge('pp_role' => 'web: server'))
    expect(result).not_to be_ok
  end

  it 'enrolls the hosts that got through and fails with the ones that did not' do
    server_runs('8.17.0-1.el10')
    agents_point_at(agent01 => server)
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
