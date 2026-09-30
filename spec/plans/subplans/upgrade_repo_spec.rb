# frozen_string_literal: true

require_relative '../spec_helper'

describe 'ovadm::subplans::upgrade_repo' do
  let(:server)   { 'ovox-server.example.com' }
  let(:compiler) { 'ovox-compiler01.example.com' }

  def installed(version, package = 'openvox-server')
    { 'version' => version, 'package' => package }
  end

  before(:each) do
    allow_task('ovadm::configure_repo').always_return('status' => 'success')
  end

  it 'leaves the repository alone within a major version' do
    allow_task('ovadm::get_version').always_return(installed('8.13.0-1.el9'))
    expect_task('ovadm::configure_repo').not_be_called

    result = run_plan('ovadm::subplans::upgrade_repo', { 'targets' => server, 'ovox_major' => 8 })
    expect(result).to be_ok
    expect(result.value).to eq([])
  end

  it 'switches to the next major version' do
    allow_task('ovadm::get_version').always_return(installed('8.16.0-1+ubuntu22.04'))
    expect_task('ovadm::configure_repo').with_params('ovox_major' => 9).be_called_times(1)

    result = run_plan('ovadm::subplans::upgrade_repo', { 'targets' => server, 'ovox_major' => 9 })
    expect(result).to be_ok
  end

  it 'switches a Puppet Server 7 node to OpenVox 8' do
    allow_task('ovadm::get_version').always_return(installed('7.17.3-1jammy', 'puppetserver'))
    expect_task('ovadm::configure_repo').with_params('ovox_major' => 8).be_called_times(1)

    result = run_plan('ovadm::subplans::upgrade_repo', { 'targets' => server, 'ovox_major' => 8 })
    expect(result).to be_ok
  end

  it 'switches a Puppet Server 8 node to OpenVox 8, the same major version' do
    allow_task('ovadm::get_version').always_return(installed('8.7.0-1.el9', 'puppetserver'))
    expect_task('ovadm::configure_repo').with_params('ovox_major' => 8).be_called_times(1)

    result = run_plan('ovadm::subplans::upgrade_repo', { 'targets' => server, 'ovox_major' => 8 })
    expect(result).to be_ok
  end

  it 'passes mirror URLs to configure_repo' do
    allow_task('ovadm::get_version').always_return(installed('8.16.0-1.el9'))
    expect_task('ovadm::configure_repo')
      .with_params('ovox_major' => 9, 'yum_base_url' => 'https://mirror.example.com/yum')
      .be_called_times(1)

    result = run_plan('ovadm::subplans::upgrade_repo', {
      'targets'      => server,
      'ovox_major'   => 9,
      'yum_base_url' => 'https://mirror.example.com/yum',
    })
    expect(result).to be_ok
  end

  it 'switches only the nodes that are behind' do
    allow_task('ovadm::get_version').return_for_targets(
      server   => installed('9.0.0-1.el9'),
      compiler => installed('8.16.0-1.el9'),
    )
    expect_task('ovadm::configure_repo').with_targets([compiler]).be_called_times(1)

    result = run_plan('ovadm::subplans::upgrade_repo', { 'targets' => [server, compiler], 'ovox_major' => 9 })
    expect(result).to be_ok
    expect(result.value.map(&:name)).to eq([compiler])
  end

  it 'changes nothing without a target major on an OpenVox node' do
    allow_task('ovadm::get_version').always_return(installed('8.13.0-1.el9'))
    expect_task('ovadm::configure_repo').not_be_called

    result = run_plan('ovadm::subplans::upgrade_repo', { 'targets' => server })
    expect(result).to be_ok
  end

  it 'fails without a target major on a Puppet Server node' do
    allow_task('ovadm::get_version').always_return(installed('7.17.3-1jammy', 'puppetserver'))

    result = run_plan('ovadm::subplans::upgrade_repo', { 'targets' => server })
    expect(result).not_to be_ok
    expect(result.value.msg).to match(/set ovox_server_version or ovox_major/)
  end

  it 'fails when nothing is installed' do
    allow_task('ovadm::get_version').always_return('version' => 'not_installed', 'package' => nil)

    result = run_plan('ovadm::subplans::upgrade_repo', { 'targets' => server, 'ovox_major' => 8 })
    expect(result).not_to be_ok
    expect(result.value.msg).to match(/use ovadm::install/)
  end

  it 'refuses to downgrade' do
    allow_task('ovadm::get_version').always_return(installed('9.0.0-1.el9'))

    result = run_plan('ovadm::subplans::upgrade_repo', { 'targets' => server, 'ovox_major' => 8 })
    expect(result).not_to be_ok
    expect(result.value.msg).to match(/does not downgrade/)
  end

  it 'refuses to skip a major version' do
    allow_task('ovadm::get_version').always_return(installed('7.17.3-1jammy', 'puppetserver'))

    result = run_plan('ovadm::subplans::upgrade_repo', { 'targets' => server, 'ovox_major' => 9 })
    expect(result).not_to be_ok
    expect(result.value.msg).to match(/one major version at a time, to 8 first/)
  end
end
