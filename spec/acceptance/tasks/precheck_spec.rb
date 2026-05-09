# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'ovadm::precheck task' do
  it 'returns a status field and a checks array' do
    result = run_bolt_task('ovadm::precheck', {})
    expect(result.exit_code).to eq(0)
    data = result.result
    expect(data).to include('status', 'checks')
    expect(data['checks']).to be_an(Array)
    expect(data['checks']).not_to be_empty
  end

  it 'includes the expected check names' do
    result = run_bolt_task('ovadm::precheck', {})
    names = result.result['checks'].map { |c| c['check'] }
    expect(names).to include('os_family', 'java', 'port_8140', 'ntp')
  end

  it 'each check has a status and detail field' do
    result = run_bolt_task('ovadm::precheck', {})
    result.result['checks'].each do |c|
      expect(c).to include('check', 'status', 'detail')
      expect(%w[pass fail warn]).to include(c['status'])
    end
  end

  it 'passes the os_family check on a supported platform' do
    result = run_bolt_task('ovadm::precheck', {})
    os_check = result.result['checks'].find { |c| c['check'] == 'os_family' }
    expect(os_check['status']).to eq('pass')
  end
end
