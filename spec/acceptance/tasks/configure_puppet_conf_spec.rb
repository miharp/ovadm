# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'ovadm::configure_puppet_conf task' do
  it 'returns success and the config file path' do
    result = run_bolt_task('ovadm::configure_puppet_conf', { 'server' => 'test.example.com' })
    expect(result.exit_code).to eq(0)
    data = result.result
    expect(data['status']).to eq('success')
    expect(data['path']).to eq('/etc/openvox/puppet.conf')
  end

  it 'reflects the server value in the response' do
    result = run_bolt_task('ovadm::configure_puppet_conf', { 'server' => 'puppet.example.com' })
    expect(result.result['server']).to eq('puppet.example.com')
  end

  it 'reflects a provided certname in the response' do
    result = run_bolt_task('ovadm::configure_puppet_conf', {
      'certname' => 'mynode.example.com',
      'server'   => 'puppet.example.com',
    })
    expect(result.result['certname']).to eq('mynode.example.com')
  end

  it 'accepts a ca_server parameter without error' do
    result = run_bolt_task('ovadm::configure_puppet_conf', {
      'server'    => 'puppet.example.com',
      'ca_server' => 'ca.example.com',
    })
    expect(result.exit_code).to eq(0)
    expect(result.result['status']).to eq('success')
  end
end
