# frozen_string_literal: true

require_relative '../spec_helper'

describe 'ovadm::subplans::precheck' do
  let(:params) { { 'server_host' => 'ovox.example.com' } }

  it 'succeeds when all checks pass' do
    allow_task('ovadm::precheck').always_return(
      'status' => 'pass',
      'checks' => [{ 'check' => 'java', 'status' => 'pass', 'detail' => 'Java 17 found' }]
    )
    result = run_plan('ovadm::subplans::precheck', params)
    expect(result).to be_ok
  end

  it 'fails the plan when precheck status is fail' do
    allow_task('ovadm::precheck').always_return(
      'status' => 'fail',
      'checks' => [{ 'check' => 'java', 'status' => 'fail', 'detail' => 'Java not found' }]
    )
    result = run_plan('ovadm::subplans::precheck', params)
    expect(result).not_to be_ok
    expect(result.value.message).to match(/Precheck failed/)
  end

  it 'succeeds and passes through warnings' do
    allow_task('ovadm::precheck').always_return(
      'status' => 'warn',
      'checks' => [
        { 'check' => 'ntp', 'status' => 'warn', 'detail' => 'NTP offset high' },
        { 'check' => 'java', 'status' => 'pass', 'detail' => 'Java 17 found' }
      ]
    )
    result = run_plan('ovadm::subplans::precheck', params)
    expect(result).to be_ok
  end
end
