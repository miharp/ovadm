# frozen_string_literal: true

require_relative 'spec_helper'

describe 'ovadm::sync_crl' do
  let(:server)   { 'ovox-server.example.com' }
  let(:compiler) { 'ovox-compiler01.example.com' }
  let(:agent)    { 'agent01.example.com' }
  let(:crl)      { "-----BEGIN X509 CRL-----\nCA\n-----END X509 CRL-----\n" }

  let(:ca_report) do
    {
      'status' => 'ok', 'certname' => server,
      'ca' => {
        'crls' => [{ 'path' => '/etc/puppetlabs/puppetserver/ca/ca_crl.pem', 'issuer' => 'CN=Puppet CA: ovox', 'crl_number' => 4, 'revoked' => 3,
                     'next_update' => '2031-11-24T13:13:03Z', 'days_left' => 1824, 'expired' => false }],
        'crl' => crl
      }
    }
  end

  def installed(target)
    { 'status' => 'updated', 'changed' => true, 'certname' => target, 'path' => '/etc/puppetlabs/puppet/ssl/crl.pem', 'host_cert_revoked' => false }
  end

  before(:each) do
    allow_task('ovadm::ca_expiry').always_return(ca_report)
    allow_task('ovadm::topology').always_return('certname' => server, 'ca' => true, 'compilers' => [compiler], 'compilers_revoked' => [])
    allow_task('ovadm::crl_install').return do |targets:, task:, params:| # rubocop:disable Lint/UnusedBlockArgument
      Bolt::ResultSet.new(targets.map { |target| Bolt::Result.new(target, value: installed(target.name)) })
    end
  end

  it 'installs the CRL on the compilers and the other hosts named' do
    expect_task('ovadm::crl_install').with_targets([compiler, agent]).with_params('crl' => crl, '_catch_errors' => true)
      .be_called_times(1).return_for_targets(compiler => installed(compiler), agent => installed(agent))
    expect_out_message.with_params("CRL of #{server} installed on 2 host(s).")

    result = run_plan('ovadm::sync_crl', { 'server_host' => server, 'compiler_hosts' => compiler, 'agent_hosts' => agent })
    expect(result).to be_ok
    expect(result.value['synced']).to eq(compiler => 'updated', agent => 'updated')
    expect(result.value['compilers_not_named']).to eq([])
  end

  it 'handles each host once and leaves the server out, when a group names them all' do
    expect_task('ovadm::crl_install').with_targets([compiler, agent]).with_params('crl' => crl, '_catch_errors' => true)
      .be_called_times(1).return_for_targets(compiler => installed(compiler), agent => installed(agent))

    result = run_plan('ovadm::sync_crl', { 'server_host' => server, 'compiler_hosts' => compiler, 'agent_hosts' => [server, compiler, agent] })
    expect(result).to be_ok
  end

  it 'restarts nothing and runs no agent' do
    expect_task('ovadm::service_restart').not_be_called
    expect_task('ovadm::agent_runonce').not_be_called

    result = run_plan('ovadm::sync_crl', { 'server_host' => server, 'compiler_hosts' => compiler })
    expect(result).to be_ok
  end

  it 'refuses more than one server' do
    result = run_plan('ovadm::sync_crl', { 'server_host' => [server, compiler], 'compiler_hosts' => compiler })
    expect(result).not_to be_ok
    expect(result.value.msg).to include('must name one host')
  end

  it 'asks for hosts when none are named' do
    expect_task('ovadm::ca_expiry').not_be_called

    result = run_plan('ovadm::sync_crl', { 'server_host' => server })
    expect(result).not_to be_ok
    expect(result.value.msg).to include('Name the hosts to install the CRL on')
  end

  it 'asks for hosts when only the server is named' do
    result = run_plan('ovadm::sync_crl', { 'server_host' => server, 'agent_hosts' => server })
    expect(result).not_to be_ok
    expect(result.value.msg).to include('Name the hosts to install the CRL on')
  end

  it 'fails with the result when a host did not get the CRL' do
    allow_task('ovadm::crl_install').return do |targets:, task:, params:| # rubocop:disable Lint/UnusedBlockArgument
      Bolt::ResultSet.new(targets.map do |target|
        if target.name == agent
          Bolt::Result.new(target, error: { 'msg' => 'Could not write crl.pem (Permission denied). Nothing was changed.', 'kind' => 'ovadm/crl-install', 'details' => {} })
        else
          Bolt::Result.new(target, value: installed(target.name))
        end
      end)
    end

    result = run_plan('ovadm::sync_crl', { 'server_host' => server, 'compiler_hosts' => compiler, 'agent_hosts' => agent })
    expect(result).not_to be_ok
    expect(result.value.kind).to eq('ovadm/sync-crl')
    expect(result.value.msg).to eq("The CRL of #{server} was not installed on #{agent}. Run the plan again for those hosts.")
    expect(result.value.details['synced']).to eq(compiler => 'updated')
    expect(result.value.details['failed'].keys).to eq([agent])
  end
end
