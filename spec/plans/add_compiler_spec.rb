# frozen_string_literal: true

require_relative 'spec_helper'

describe 'ovadm::add_compiler' do
  let(:server)   { 'ovox-server.example.com' }
  let(:compiler) { 'ovox-compiler02.example.com' }

  before(:each) do
    execute_no_plan
    allow_command('systemctl enable --now puppetserver').always_return('stdout' => '', 'stderr' => '')
    allow_task('ovadm::configure_compiler_ssl').always_return('status' => 'success')
  end

  it 'prechecks compilers, installs agent, and sets up certificates' do
    expect_plan('ovadm::subplans::precheck').be_called_times(1)
    expect_plan('ovadm::subplans::agent_install').be_called_times(1)
    expect_plan('ovadm::subplans::cert_setup').be_called_times(1)
    expect_task('ovadm::configure_compiler_ssl').be_called_times(1)

    allow_command('hostname -f').always_return('stdout' => "#{server}\n", 'stderr' => '')

    result = run_plan('ovadm::add_compiler', {
      'server_host'    => server,
      'compiler_hosts' => compiler
    })
    expect(result).to be_ok
  end
end
