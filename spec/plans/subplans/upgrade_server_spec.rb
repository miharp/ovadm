# frozen_string_literal: true

require_relative '../spec_helper'

describe 'ovadm::subplans::upgrade_server' do
  let(:server)         { 'ovox-server.example.com' }
  let(:server_version) { '8.13.0' }
  let(:params) do
    { 'server_host' => server, 'ovox_server_version' => server_version, 'ovox_major' => 8 }
  end

  before(:each) do
    allow_task('ovadm::configure_repo').always_return('status' => 'success')
    allow_task('ovadm::install_server').always_return('status' => 'success', 'version' => server_version)
    allow_task('ovadm::select_java').always_return('status' => 'unchanged')
    allow_task('ovadm::service_restart').always_return('status' => 'success')
    allow_task('ovadm::wait_until_service_ready').always_return('status' => 'success')
    allow_task('ovadm::get_version').always_return('version' => "#{server_version}-1.el9", 'package' => 'openvox-server')
  end

  it 'installs the server, selects Java, restarts, and waits for readiness' do
    expect_task('ovadm::configure_repo').not_be_called
    expect_task('ovadm::install_server').be_called_times(1)
    expect_task('ovadm::select_java').be_called_times(1)
    expect_task('ovadm::service_restart').be_called_times(1)
    expect_task('ovadm::wait_until_service_ready').be_called_times(1)

    result = run_plan('ovadm::subplans::upgrade_server', params)
    expect(result).to be_ok
  end

  it 'switches the repository first on a Puppet Server 7 node' do
    allow_task('ovadm::get_version').always_return('version' => '7.17.3-1jammy', 'package' => 'puppetserver')
    expect_task('ovadm::configure_repo').with_params('ovox_major' => 8).be_called_times(1)
    expect_task('ovadm::install_server').with_params('version' => server_version).be_called_times(1)

    result = run_plan('ovadm::subplans::upgrade_server', params)
    expect(result).to be_ok
  end

  it 'passes package_url to install_server when provided' do
    pkg_url = 'https://s3.example.com/openvox-server-9.0.0.rpm'

    expect_task('ovadm::install_server')
      .with_params('package_url' => pkg_url)
      .be_called_times(1)
      .always_return('status' => 'success', 'version' => '9.0.0')

    result = run_plan('ovadm::subplans::upgrade_server', {
      'server_host' => server,
      'package_url' => pkg_url,
    })
    expect(result).to be_ok
  end
end
