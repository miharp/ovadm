# frozen_string_literal: true

require_relative '../spec_helper'

describe 'ovadm::subplans::cert_setup' do
  let(:server)   { 'ovox-server.example.com' }
  let(:compiler) { 'ovox-compiler01.example.com' }
  let(:params) do
    { 'server_host' => server, 'compiler_hosts' => compiler }
  end

  before(:each) do
    allow_command('hostname -f').always_return('stdout' => "#{compiler}\n", 'stderr' => '')
  end

  it 'sets csr_attributes, submits CSR, signs it, and runs agent to apply catalog' do
    expect_task('ovadm::set_csr_attributes')
      .with_params('pp_role' => 'openvox_compiler')
      .be_called_times(1)
      .always_return('status' => 'success')
    expect_task('ovadm::agent_runonce').be_called_times(2).always_return('status' => 'no_changes', 'exit_code' => 0)
    expect_task('ovadm::sign_csr').be_called_times(1).always_return('status' => 'signed', 'certname' => compiler)

    result = run_plan('ovadm::subplans::cert_setup', params)
    expect(result).to be_ok
  end

  it 'passes openvox_compiler as the pp_role value' do
    allow_task('ovadm::set_csr_attributes').always_return('status' => 'success')
    allow_task('ovadm::agent_runonce').always_return('status' => 'no_changes', 'exit_code' => 0)
    allow_task('ovadm::sign_csr').always_return('status' => 'signed', 'certname' => compiler)

    expect_task('ovadm::set_csr_attributes').with_params('pp_role' => 'openvox_compiler')

    run_plan('ovadm::subplans::cert_setup', params)
  end
end
