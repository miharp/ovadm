# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'ovadm::set_csr_attributes task' do
  it 'writes the csr_attributes file and returns success' do
    result = run_bolt_task('ovadm::set_csr_attributes', { 'pp_role' => 'openvox_compiler' })
    expect(result.exit_code).to eq(0)
    data = result.result
    expect(data['status']).to eq('success')
    expect(data['path']).to eq('/etc/puppetlabs/puppet/csr_attributes.yaml')
    expect(data['pp_role']).to eq('openvox_compiler')
  end

  it 'reflects an arbitrary pp_role value in the response' do
    result = run_bolt_task('ovadm::set_csr_attributes', { 'pp_role' => 'ovadm_server' })
    expect(result.exit_code).to eq(0)
    expect(result.result['pp_role']).to eq('ovadm_server')
  end
end
