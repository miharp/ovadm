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
    # The plan checks what actually landed, so the stub has to report a version.
    allow_task('ovadm::install_codavox').always_return('status' => 'success', 'version' => '0.5.0')
    allow_task('ovadm::configure_codavox').always_return('status' => 'success')
    allow_task('ovadm::seed_environment').always_return('status' => 'success')
    allow_task('ovadm::wait_for_environment').always_return('status' => 'success')
    allow_task('ovadm::wire_codavox').always_return('status' => 'success')
    allow_task('ovadm::wait_until_service_ready').always_return('status' => 'ready')
    allow_task('ovadm::verify_fleet').always_return(
      'status' => 'success', 'compilers' => 1, 'code_id' => 'abc123', 'certnames' => compiler
    )
  end

  it 'installs, configures both roles, serves, converges, then wires the compilers' do
    expect_task('ovadm::install_codavox')
      .always_return('status' => 'success', 'version' => '0.5.0')
      .be_called_times(1)
    # publisher on the server, agent on the compilers
    expect_task('ovadm::configure_codavox').be_called_times(2)
    expect_task('ovadm::seed_environment').be_called_times(1)
    # convergence must be waited on before wiring OpenVox Server
    expect_task('ovadm::wait_for_environment').be_called_times(1)
    expect_task('ovadm::wire_codavox').be_called_times(1)
    # the restart must leave puppetserver ready before the plan returns
    expect_task('ovadm::wait_until_service_ready').be_called_times(1)
    # and the publisher must confirm the fleet converged, not just each node
    expect_task('ovadm::verify_fleet').be_called_times(1)

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

  # The count comes from the compiler list, so a two-compiler run must require
  # both to report. Passing 1 would let a half-converged fleet look converged.
  it 'requires every compiler to report to the publisher' do
    expect_task('ovadm::verify_fleet')
      .with_params('expected' => 2, 'publisher' => "https://#{server}:8150")
      .be_called_times(1)

    result = run_plan('ovadm::codavox', {
      'server_host'    => server,
      'compiler_hosts' => [compiler, 'ovox-compiler02.example.com']
    })
    expect(result).to be_ok
  end

  # A stale package cache or a wrong URL otherwise surfaces much later as a daemon
  # that will not start, with an error pointing at the config rather than the
  # version — because codavox rejects config keys an older binary does not know.
  it 'fails when the installed codavox is not the one requested' do
    allow_task('ovadm::install_codavox').always_return('status' => 'success', 'version' => '0.4.0')

    result = run_plan('ovadm::codavox', {
      'server_host'    => server,
      'compiler_hosts' => compiler,
      'codavox_version' => '0.5.0'
    })
    expect(result).not_to be_ok
    expect(result.value.msg).to match(%r{has codavox 0\.4\.0, but 0\.5\.0 was requested})
  end

  # A snapshot has no version to compare against, so the check has to stand down
  # rather than fail every local test of unreleased code.
  it 'skips the version check when a package_url is given' do
    allow_task('ovadm::install_codavox').always_return('status' => 'success', 'version' => '0.6.0-next')

    result = run_plan('ovadm::codavox', {
      'server_host'    => server,
      'compiler_hosts' => compiler,
      'package_url'    => 'https://example.com/codavox_snapshot_linux_amd64.rpm'
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
