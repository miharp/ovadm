# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'ovadm::os_identification task' do
  it 'returns os_family, os_name, os_release, and arch' do
    result = run_bolt_task('ovadm::os_identification', {})
    expect(result.exit_code).to eq(0)
    data = result.result
    expect(data).to include('os_family', 'os_name', 'os_release', 'arch')
  end

  it 'returns a recognised OS family' do
    result = run_bolt_task('ovadm::os_identification', {})
    expect(%w[Debian RedHat]).to include(result.result['os_family'])
  end

  it 'returns a non-empty arch' do
    result = run_bolt_task('ovadm::os_identification', {})
    expect(result.result['arch']).not_to be_empty
  end
end
