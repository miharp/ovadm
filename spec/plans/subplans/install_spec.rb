# frozen_string_literal: true

require_relative '../spec_helper'

describe 'ovadm::subplans::install' do
  let(:server) { 'ovox-server.example.com' }

  before(:each) do
    allow_task('ovadm::install_server').always_return('status' => 'success')
  end

  it 'calls configure_repo and install_server' do
    expect_task('ovadm::configure_repo').be_called_times(1).always_return('status' => 'success')
    expect_task('ovadm::install_server').be_called_times(1)

    result = run_plan('ovadm::subplans::install', { 'server_host' => server })
    expect(result).to be_ok
  end

  it 'forwards apt_base_url to configure_repo when provided' do
    expect_task('ovadm::configure_repo')
      .with_params('ovox_major' => 8, 'apt_base_url' => 'https://packages.example.com/vox-apt')
      .always_return('status' => 'success')

    run_plan('ovadm::subplans::install', {
      'server_host'  => server,
      'apt_base_url' => 'https://packages.example.com/vox-apt',
    })
  end

  it 'forwards yum_base_url to configure_repo when provided' do
    expect_task('ovadm::configure_repo')
      .with_params('ovox_major' => 8, 'yum_base_url' => 'https://packages.example.com/vox-yum')
      .always_return('status' => 'success')

    run_plan('ovadm::subplans::install', {
      'server_host'  => server,
      'yum_base_url' => 'https://packages.example.com/vox-yum',
    })
  end

  it 'forwards both URL params to configure_repo when provided' do
    expect_task('ovadm::configure_repo')
      .with_params(
        'ovox_major'   => 8,
        'apt_base_url' => 'https://packages.example.com/vox-apt',
        'yum_base_url' => 'https://packages.example.com/vox-yum',
      )
      .always_return('status' => 'success')

    run_plan('ovadm::subplans::install', {
      'server_host'  => server,
      'apt_base_url' => 'https://packages.example.com/vox-apt',
      'yum_base_url' => 'https://packages.example.com/vox-yum',
    })
  end
end
