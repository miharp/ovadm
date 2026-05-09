# frozen_string_literal: true

require 'spec_helper'

# run_bolt_task returns an OpenStruct with:
#   .exit_code  — 0 on success
#   .result     — parsed JSON hash

RSpec.describe 'ovadm::service_status task' do
  it 'returns a single JSON object with a services array' do
    result = run_bolt_task('ovadm::service_status', {})
    expect(result.exit_code).to eq(0)
    data = result.result
    expect(data).to include('services')
    expect(data['services']).to be_an(Array)
    expect(data['services']).not_to be_empty
  end

  it 'includes service name and status fields for each entry' do
    result = run_bolt_task('ovadm::service_status', {})
    data = result.result
    data['services'].each do |svc|
      expect(svc).to include('service', 'status')
      expect(%w[running stopped]).to include(svc['status'])
    end
  end

  it 'reports stopped on a fresh node without puppetserver installed' do
    result = run_bolt_task('ovadm::service_status', {})
    statuses = result.result['services'].map { |s| s['status'] }
    expect(statuses).to all(eq('stopped'))
  end
end
