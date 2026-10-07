# frozen_string_literal: true

require_relative 'spec_helper'

describe 'ovadm::add_compiler' do
  let(:server)   { 'ovox-server.example.com' }
  let(:compiler) { 'ovox-compiler02.example.com' }
  let(:params)   { { 'server_host' => server, 'compiler_hosts' => compiler } }

  before(:each) do
    execute_no_plan
    allow_command('systemctl enable --now puppetserver').always_return('stdout' => '', 'stderr' => '')
    allow_command('hostname -f').always_return('stdout' => "#{server}\n", 'stderr' => '')
    allow_task('ovadm::configure_compiler_ssl').always_return('status' => 'success')
  end

  def agent_install_params(server_version)
    {
      'compiler_hosts'      => compiler,
      'server_fqdn'         => server,
      'ovox_version'        => nil,
      'ovox_server_version' => server_version,
      'apt_base_url'        => nil,
      'yum_base_url'        => nil,
      'package_url'         => nil,
    }
  end

  def server_runs(version, package = 'openvox-server')
    expect_task('ovadm::get_version').with_targets(server).always_return('version' => version, 'package' => package)
  end

  it 'prechecks compilers, installs agent, and sets up certificates' do
    server_runs('8.16.0-1+ubuntu24.04')
    expect_plan('ovadm::subplans::precheck').be_called_times(1)
    expect_plan('ovadm::subplans::agent_install').be_called_times(1)
    expect_plan('ovadm::subplans::cert_setup').be_called_times(1)
    expect_task('ovadm::configure_compiler_ssl').be_called_times(1)

    result = run_plan('ovadm::add_compiler', params)
    expect(result).to be_ok
  end

  context 'without a version' do
    it 'gives the compilers the version the server runs' do
      server_runs('9.0.1-1.el10')
      expect_plan('ovadm::subplans::precheck').with_params('server_host' => compiler, 'ovox_major' => 9)
      expect_plan('ovadm::subplans::agent_install').with_params(agent_install_params('9.0.1'))
      allow_plan('ovadm::subplans::cert_setup')

      result = run_plan('ovadm::add_compiler', params)
      expect(result).to be_ok
    end

    it 'keeps a pre-release version whole' do
      server_runs('9.0.0~rc2-1.el10')
      allow_plan('ovadm::subplans::precheck')
      expect_plan('ovadm::subplans::agent_install').with_params(agent_install_params('9.0.0~rc2'))
      allow_plan('ovadm::subplans::cert_setup')

      result = run_plan('ovadm::add_compiler', params)
      expect(result).to be_ok
    end

    it 'stops when the server is still on Puppet Server' do
      server_runs('7.17.3-1jammy', 'puppetserver')
      expect_plan('ovadm::subplans::agent_install').not_be_called

      result = run_plan('ovadm::add_compiler', params)
      expect(result).not_to be_ok
      expect(result.value.message).to match(/has puppetserver 7\.17\.3-1jammy.*ovadm::upgrade first, or pass ovox_server_version/)
    end
  end

  it 'installs the version given without asking the server' do
    expect_task('ovadm::get_version').not_be_called
    expect_plan('ovadm::subplans::precheck').with_params('server_host' => compiler, 'ovox_major' => 8)
    expect_plan('ovadm::subplans::agent_install').with_params(agent_install_params('8.13.0'))
    allow_plan('ovadm::subplans::cert_setup')

    result = run_plan('ovadm::add_compiler', params.merge('ovox_server_version' => '8.13.0'))
    expect(result).to be_ok
  end
end
