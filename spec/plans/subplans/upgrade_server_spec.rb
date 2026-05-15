# frozen_string_literal: true

require_relative '../spec_helper'

describe 'ovadm::subplans::upgrade_server' do
  let(:server)         { 'ovox-server.example.com' }
  let(:server_version) { '8.13.0' }
  let(:params) do
    { 'server_host' => server, 'ovox_server_version' => server_version }
  end

  before(:each) do
    allow_task('ovadm::install_server').always_return('status' => 'success', 'version' => server_version)
    allow_task('ovadm::service_restart').always_return('status' => 'success')
    allow_task('ovadm::wait_until_service_ready').always_return('status' => 'success')
    allow_task('ovadm::get_version').always_return('version' => "#{server_version}-1.el9")
  end

  it 'installs the server, restarts, and waits for readiness' do
    expect_task('ovadm::install_server').be_called_times(1)
    expect_task('ovadm::service_restart').be_called_times(1)
    expect_task('ovadm::wait_until_service_ready').be_called_times(1)

    result = run_plan('ovadm::subplans::upgrade_server', params)
    expect(result).to be_ok
  end
end
