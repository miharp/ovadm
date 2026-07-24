# frozen_string_literal: true

require_relative 'spec_helper'

describe 'ovadm::codavox' do
  let(:server)   { 'ovox-server.example.com' }
  let(:compiler) { 'ovox-compiler01.example.com' }

  before(:each) do
    execute_no_plan
    allow_command('hostname -f').always_return('stdout' => "#{server}\n", 'stderr' => '')
    allow_command('systemctl enable --now codavox-publish').always_return('stdout' => '', 'stderr' => '')
    allow_command('systemctl enable --now codavox-agent').always_return('stdout' => '', 'stderr' => '')
    allow_command('systemctl restart puppetserver').always_return('stdout' => '', 'stderr' => '')
    allow_task('ovadm::install_codavox').always_return('status' => 'success')
    allow_task('ovadm::configure_codavox').always_return('status' => 'success')
    allow_task('ovadm::seed_environment').always_return('status' => 'success')
    allow_task('ovadm::wait_for_environment').always_return('status' => 'success')
    allow_task('ovadm::wire_codavox').always_return('status' => 'success')
  end

  it 'installs, configures both roles, serves, converges, then wires the compilers' do
    expect_task('ovadm::install_codavox').be_called_times(1)
    # publisher on the server, agent on the compilers
    expect_task('ovadm::configure_codavox').be_called_times(2)
    expect_task('ovadm::seed_environment').be_called_times(1)
    # convergence must be waited on before wiring OpenVox Server
    expect_task('ovadm::wait_for_environment').be_called_times(1)
    expect_task('ovadm::wire_codavox').be_called_times(1)

    result = run_plan('ovadm::codavox', {
      'server_host'    => server,
      'compiler_hosts' => compiler
    })
    expect(result).to be_ok
  end

  it 'does not enable the deploy server by default' do
    # The deploy-server command is not allowed, so the plan calling it would
    # fail. A passing run proves it stays off unless requested.
    result = run_plan('ovadm::codavox', {
      'server_host'    => server,
      'compiler_hosts' => compiler
    })
    expect(result).to be_ok
  end

  it 'enables the deploy server when requested' do
    allow_command('systemctl enable --now codavox-deploy-server').always_return('stdout' => '', 'stderr' => '')
    expect_command('systemctl enable --now codavox-deploy-server').be_called_times(1)

    result = run_plan('ovadm::codavox', {
      'server_host'    => server,
      'compiler_hosts' => compiler,
      'deploy_server'  => true
    })
    expect(result).to be_ok
  end
end
