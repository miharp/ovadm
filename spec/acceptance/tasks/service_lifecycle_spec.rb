# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'ovadm service lifecycle tasks' do
  it 'service_stop returns a recognised status' do
    result = run_bolt_task('ovadm::service_stop', {})
    expect(result.exit_code).to eq(0)
    expect(%w[stopped not_installed]).to include(result.result['status'])
    expect(result.result['service']).to eq('puppetserver')
  end

  it 'service_start returns a recognised status' do
    result = run_bolt_task('ovadm::service_start', {})
    expect(result.exit_code).to eq(0)
    expect(%w[started not_installed]).to include(result.result['status'])
    expect(result.result['service']).to eq('puppetserver')
  end

  it 'service_restart returns a recognised status' do
    result = run_bolt_task('ovadm::service_restart', {})
    expect(result.exit_code).to eq(0)
    expect(%w[restarted not_installed]).to include(result.result['status'])
    expect(result.result['service']).to eq('puppetserver')
  end
end
