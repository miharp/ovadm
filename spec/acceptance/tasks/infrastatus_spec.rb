# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'ovadm::infrastatus task' do
  it 'returns version, service, and port_8140 fields' do
    result = run_bolt_task('ovadm::infrastatus', {})
    expect(result.exit_code).to eq(0)
    expect(result.result).to include('version', 'service', 'port_8140')
  end

  it 'returns a recognised service state' do
    result = run_bolt_task('ovadm::infrastatus', {})
    expect(%w[running stopped]).to include(result.result['service'])
  end

  it 'returns a recognised port_8140 state' do
    result = run_bolt_task('ovadm::infrastatus', {})
    expect(%w[listening not_listening]).to include(result.result['port_8140'])
  end
end
