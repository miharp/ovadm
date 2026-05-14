# frozen_string_literal: true

require_relative '../spec_helper'

describe 'ovadm::subplans::agent_install' do
  let(:compiler) { 'ovox-compiler01.example.com' }
  let(:server)   { 'ovox-server.example.com' }
  let(:params) do
    { 'compiler_hosts' => compiler, 'server_fqdn' => server }
  end

  before(:each) do
    allow_task('ovadm::install_server').always_return('status' => 'success')
    allow_task('ovadm::configure_puppet_conf').always_return('status' => 'success')
  end

  it 'calls configure_repo, install_server, and configure_puppet_conf' do
    expect_task('ovadm::configure_repo').be_called_times(1).always_return('status' => 'success')
    expect_task('ovadm::install_server').be_called_times(1)
    expect_task('ovadm::configure_puppet_conf').be_called_times(1)

    result = run_plan('ovadm::subplans::agent_install', params)
    expect(result).to be_ok
  end

  it 'forwards apt_base_url to configure_repo when provided' do
    expect_task('ovadm::configure_repo')
      .with_params('ovox_major' => 8, 'apt_base_url' => 'https://packages.example.com/vox-apt')
      .always_return('status' => 'success')

    run_plan('ovadm::subplans::agent_install', params.merge(
      'apt_base_url' => 'https://packages.example.com/vox-apt',
    ))
  end

  it 'forwards yum_base_url to configure_repo when provided' do
    expect_task('ovadm::configure_repo')
      .with_params('ovox_major' => 8, 'yum_base_url' => 'https://packages.example.com/vox-yum')
      .always_return('status' => 'success')

    run_plan('ovadm::subplans::agent_install', params.merge(
      'yum_base_url' => 'https://packages.example.com/vox-yum',
    ))
  end

  it 'forwards both URL params to configure_repo when provided' do
    expect_task('ovadm::configure_repo')
      .with_params(
        'ovox_major'   => 8,
        'apt_base_url' => 'https://packages.example.com/vox-apt',
        'yum_base_url' => 'https://packages.example.com/vox-yum',
      )
      .always_return('status' => 'success')

    run_plan('ovadm::subplans::agent_install', params.merge(
      'apt_base_url' => 'https://packages.example.com/vox-apt',
      'yum_base_url' => 'https://packages.example.com/vox-yum',
    ))
  end
end
