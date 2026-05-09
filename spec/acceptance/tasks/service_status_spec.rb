# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'ovadm::service_status task' do
  it 'returns a single JSON object with a services array' do
    result = run_bolt_task('ovadm::service_status', {})
    expect(result).to be_ok
    data = result.first['value']
    expect(data).to include('services')
    expect(data['services']).to be_an(Array)
    expect(data['services']).not_to be_empty
  end

  it 'includes service name and status fields for each entry' do
    result = run_bolt_task('ovadm::service_status', {})
    data = result.first['value']
    data['services'].each do |svc|
      expect(svc).to include('service', 'status')
      expect(%w[running stopped]).to include(svc['status'])
    end
  end

  it 'reports stopped on a fresh node without puppetserver installed' do
    result = run_bolt_task('ovadm::service_status', {})
    data = result.first['value']
    statuses = data['services'].map { |s| s['status'] }
    expect(statuses).to all(eq('stopped'))
  end
end
