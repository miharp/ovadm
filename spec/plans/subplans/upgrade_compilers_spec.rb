# frozen_string_literal: true

require_relative '../spec_helper'

describe 'ovadm::subplans::upgrade_compilers' do
  let(:compiler)       { 'ovox-compiler01.example.com' }
  let(:server_version) { '8.13.0' }
  let(:params) do
    { 'compiler_hosts' => compiler, 'ovox_server_version' => server_version, 'ovox_major' => 8 }
  end

  before(:each) do
    allow_task('ovadm::get_version').always_return('version' => '8.12.1-1.el9', 'package' => 'openvox-server')
    allow_task('ovadm::configure_repo').always_return('status' => 'success')
    allow_task('ovadm::install_server').always_return('status' => 'success', 'version' => server_version)
    allow_task('ovadm::select_java').always_return('status' => 'unchanged')
    allow_task('ovadm::service_restart').always_return('status' => 'success')
    allow_task('ovadm::wait_until_service_ready').always_return('status' => 'success')
  end

  it 'installs the server, selects Java, restarts, and waits for readiness on compilers' do
    expect_task('ovadm::configure_repo').not_be_called
    expect_task('ovadm::install_server').be_called_times(1)
    expect_task('ovadm::select_java').be_called_times(1)
    expect_task('ovadm::service_restart').be_called_times(1)
    expect_task('ovadm::wait_until_service_ready').be_called_times(1)

    result = run_plan('ovadm::subplans::upgrade_compilers', params)
    expect(result).to be_ok
  end

  it 'switches the repository first when moving to a new major version' do
    expect_task('ovadm::configure_repo').with_params('ovox_major' => 9).be_called_times(1)

    result = run_plan('ovadm::subplans::upgrade_compilers', params.merge('ovox_server_version' => '9.0.0', 'ovox_major' => 9))
    expect(result).to be_ok
  end
end
