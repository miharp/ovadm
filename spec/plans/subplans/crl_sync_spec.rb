# frozen_string_literal: true

require_relative '../spec_helper'

describe 'ovadm::subplans::crl_sync' do
  let(:server)     { 'ovox-server.example.com' }
  let(:compiler01) { 'ovox-compiler01.example.com' }
  let(:compiler02) { 'ovox-compiler02.example.com' }
  let(:hostcrl)    { '/etc/puppetlabs/puppet/ssl/crl.pem' }
  let(:crl)        { "-----BEGIN X509 CRL-----\nCA\n-----END X509 CRL-----\n" }
  let(:params)     { { 'server_host' => server, 'hosts' => [compiler01, compiler02] } }

  def ca_crl(path, number, revoked)
    { 'path' => path, 'issuer' => 'CN=Puppet CA: ovox', 'last_update' => '2026-11-25T13:13:03Z',
      'next_update' => '2031-11-24T13:13:03Z', 'days_left' => 1824, 'expired' => false, 'crl_number' => number, 'revoked' => revoked }
  end

  # What ca_expiry says on the CA host with include_bundle.
  def ca_report(crl_pem: crl)
    {
      'status' => 'ok', 'certname' => server,
      'ca' => {
        'path' => '/etc/puppetlabs/puppetserver/ca/ca_crt.pem',
        'crls' => [ca_crl('/etc/puppetlabs/puppetserver/ca/ca_crl.pem', 4, 3), ca_crl('/etc/puppetlabs/puppetserver/ca/infra_crl.pem', 0, 0)],
        'bundle' => 'BUNDLE', 'crl' => crl_pem
      }
    }
  end

  def topology(compilers: [compiler01, compiler02], revoked: [])
    { 'certname' => server, 'ca' => true, 'compilers' => compilers, 'compilers_revoked' => revoked }
  end

  def installed(certname, status: 'updated', revoked: false)
    { 'status' => status, 'changed' => status == 'updated', 'certname' => certname, 'path' => hostcrl, 'host_cert_revoked' => revoked }
  end

  # crl_install answering each target by name: a value, or an error message.
  def crl_install_returns(answers)
    allow_task('ovadm::crl_install').return do |targets:, task:, params:| # rubocop:disable Lint/UnusedBlockArgument
      Bolt::ResultSet.new(targets.map do |target|
        answer = answers.fetch(target.name) { installed(target.name) }
        if answer.is_a?(String)
          Bolt::Result.new(target, error: { 'msg' => answer, 'kind' => 'ovadm/crl-install', 'details' => {} })
        else
          Bolt::Result.new(target, value: answer)
        end
      end)
    end
  end

  before(:each) do
    allow_task('ovadm::ca_expiry').always_return(ca_report)
    allow_task('ovadm::topology').always_return(topology)
    crl_install_returns({})
  end

  it 'reads the CRLs from the CA directory and installs them on every host at once' do
    expect_task('ovadm::ca_expiry').with_targets(server).with_params('include_bundle' => true).be_called_times(1).always_return(ca_report)
    expect_task('ovadm::crl_install').with_targets([compiler01, compiler02]).with_params('crl' => crl, '_catch_errors' => true)
      .be_called_times(1).return_for_targets(compiler01 => installed(compiler01), compiler02 => installed(compiler02, status: 'unchanged'))
    expect_out_message.with_params("#{compiler01}: CRL updated (#{hostcrl})")
    expect_out_message.with_params("#{compiler02}: already has the CRL")

    result = run_plan('ovadm::subplans::crl_sync', params)
    expect(result).to be_ok
    expect(result.value['synced']).to eq(compiler01 => 'updated', compiler02 => 'unchanged')
    expect(result.value['failed']).to eq({})
    expect(result.value['host_cert_revoked']).to eq([])
    expect(result.value['compilers_not_named']).to eq([])
  end

  it "returns the CA's own CRLs and leaves the infrastructure CRL out" do
    result = run_plan('ovadm::subplans::crl_sync', params)
    expect(result.value['crls']).to eq([
      { 'issuer' => 'CN=Puppet CA: ovox', 'next_update' => '2031-11-24T13:13:03Z', 'days_left' => 1824, 'expired' => false, 'crl_number' => 4, 'revoked' => 3 }
    ])
  end

  it 'stops on a server that is not the CA, with the kind it was given' do
    allow_task('ovadm::ca_expiry').always_return('status' => 'ok', 'certname' => server, 'ca' => nil)
    expect_task('ovadm::crl_install').not_be_called

    result = run_plan('ovadm::subplans::crl_sync', params.merge('kind' => 'ovadm/revoke'))
    expect(result).not_to be_ok
    expect(result.value.msg).to include('has no CA directory')
    expect(result.value.kind).to eq('ovadm/revoke')
  end

  it 'stops when the CA directory holds no CRL' do
    allow_task('ovadm::ca_expiry').always_return(ca_report(crl_pem: nil))
    expect_task('ovadm::crl_install').not_be_called

    result = run_plan('ovadm::subplans::crl_sync', params)
    expect(result).not_to be_ok
    expect(result.value.msg).to include('has no CRL in its CA directory')
  end

  it 'goes on with the other hosts when one fails, and reports it' do
    crl_install_returns(compiler02 => 'The CRL of CN=Puppet CA: other given is not signed by a certificate in ca.pem. Nothing was changed.')
    expect_out_message.with_params("ERROR #{compiler02}: The CRL of CN=Puppet CA: other given is not signed by a certificate in ca.pem. Nothing was changed.")

    result = run_plan('ovadm::subplans::crl_sync', params)
    expect(result).to be_ok
    expect(result.value['synced']).to eq(compiler01 => 'updated')
    expect(result.value['failed'].keys).to eq([compiler02])
    # A compiler that did not get the CRL is named, whatever the reason.
    expect(result.value['compilers_not_named']).to eq([compiler02])
  end

  it 'counts a host without the agent, or with no CA, as failed' do
    crl_install_returns(
      compiler01 => { 'status' => 'not_installed', 'changed' => false },
      compiler02 => { 'status' => 'not_enrolled', 'changed' => false, 'certname' => compiler02, 'detail' => '/etc/puppetlabs/puppet/ssl/certs/ca.pem does not exist' },
    )

    result = run_plan('ovadm::subplans::crl_sync', params)
    expect(result.value['synced']).to eq({})
    expect(result.value['failed']).to eq(
      compiler01 => 'the OpenVox agent is not installed there',
      compiler02 => 'it trusts no CA (/etc/puppetlabs/puppet/ssl/certs/ca.pem does not exist)',
    )
  end

  it 'reports a host that keeps a newer CRL, or none, without failing it' do
    crl_install_returns(compiler01 => installed(compiler01, status: 'kept_newer'), compiler02 => installed(compiler02, status: 'absent'))
    expect_out_message.with_params("#{compiler01}: holds a newer CRL than #{server} and keeps it")
    expect_out_message.with_params("#{compiler02}: keeps no CRL, so nothing was installed; its next agent run fetches the list")

    result = run_plan('ovadm::subplans::crl_sync', params)
    expect(result.value['synced']).to eq(compiler01 => 'kept_newer', compiler02 => 'absent')
    expect(result.value['failed']).to eq({})
  end

  it 'names a host whose own certificate is on the CRL' do
    crl_install_returns(compiler02 => installed(compiler02, revoked: true))
    expect_out_message.with_params(
      "WARNING #{compiler02}: its own certificate (#{compiler02}) is revoked. Agents refuse it; stop puppetserver there and take it out of the pool.",
    )

    result = run_plan('ovadm::subplans::crl_sync', params)
    expect(result.value['host_cert_revoked']).to eq([compiler02])
  end

  it 'names the compilers the server knows of that were not among the hosts' do
    expect_out_message.with_params(
      "WARNING #{server} knows of 1 compiler(s) that did not get the CRL: #{compiler02}. " \
      'Each goes on serving a revoked host until its copy is replaced: run ovadm::sync_crl with them in compiler_hosts.',
    )

    result = run_plan('ovadm::subplans::crl_sync', params.merge('hosts' => [compiler01]))
    expect(result.value['compilers_not_named']).to eq([compiler02])
  end

  it 'does not ask for a compiler that is revoked' do
    allow_task('ovadm::topology').always_return(topology(revoked: [compiler02]))

    result = run_plan('ovadm::subplans::crl_sync', params.merge('hosts' => [compiler01]))
    expect(result.value['compilers_not_named']).to eq([])
  end

  it 'matches compilers by certname, not by the name Bolt knows the host under' do
    crl_install_returns('c1' => installed(compiler01), 'c2' => installed(compiler02))

    result = run_plan('ovadm::subplans::crl_sync', params.merge('hosts' => %w[c1 c2]))
    expect(result.value['synced']).to eq('c1' => 'updated', 'c2' => 'updated')
    expect(result.value['compilers_not_named']).to eq([])
  end

  it 'installs nothing when no host is given, and still names the compilers' do
    expect_task('ovadm::crl_install').not_be_called

    result = run_plan('ovadm::subplans::crl_sync', { 'server_host' => server })
    expect(result).to be_ok
    expect(result.value['synced']).to eq({})
    expect(result.value['compilers_not_named']).to eq([compiler01, compiler02])
  end
end
