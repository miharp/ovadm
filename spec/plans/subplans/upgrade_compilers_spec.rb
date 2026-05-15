# frozen_string_literal: true

require_relative '../spec_helper'

describe 'ovadm::subplans::upgrade_compilers' do
  let(:compiler)       { 'ovox-compiler01.example.com' }
  let(:server_version) { '8.13.0' }
  let(:params) do
    { 'compiler_hosts' => compiler, 'ovox_server_version' => server_version }
  end

  before(:each) do
    allow_task('ovadm::install_server').always_return('status' => 'success', 'version' => server_version)
    allow_task('ovadm::service_restart').always_return('status' => 'success')
    allow_task('ovadm::wait_until_service_ready').always_return('status' => 'success')
  end

  it 'installs the server, restarts, and waits for readiness on compilers' do
    expect_task('ovadm::install_server').be_called_times(1)
    expect_task('ovadm::service_restart').be_called_times(1)
    expect_task('ovadm::wait_until_service_ready').be_called_times(1)

    result = run_plan('ovadm::subplans::upgrade_compilers', params)
    expect(result).to be_ok
  end
end
