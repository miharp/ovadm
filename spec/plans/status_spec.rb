# frozen_string_literal: true

require_relative 'spec_helper'

describe 'ovadm::status' do
  let(:server) { 'ovox.example.com' }

  let(:precheck_result) do
    {
      'status' => 'pass',
      'checks' => [{ 'check' => 'java', 'status' => 'pass', 'detail' => 'Java 17 found' }]
    }
  end

  let(:service_result) do
    { 'services' => [{ 'service' => 'puppetserver', 'status' => 'running' }] }
  end

  let(:version_result) { { 'version' => '8.3.1' } }

  it 'runs precheck, service_status, and get_version' do
    expect_task('ovadm::precheck').be_called_times(1).always_return(precheck_result)
    expect_task('ovadm::service_status').be_called_times(1).always_return(service_result)
    expect_task('ovadm::get_version').be_called_times(1).always_return(version_result)

    result = run_plan('ovadm::status', { 'server_host' => server })
    expect(result).to be_ok
  end

  it 'returns a hash with precheck, services, and versions keys' do
    allow_task('ovadm::precheck').always_return(precheck_result)
    allow_task('ovadm::service_status').always_return(service_result)
    allow_task('ovadm::get_version').always_return(version_result)

    result = run_plan('ovadm::status', { 'server_host' => server })
    expect(result).to be_ok
    expect(result.value.keys).to contain_exactly('precheck', 'services', 'versions')
  end
end
