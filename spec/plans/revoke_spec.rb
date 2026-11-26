# frozen_string_literal: true

require_relative 'spec_helper'

describe 'ovadm::revoke' do
  let(:server)   { 'ovox-server.example.com' }
  let(:compiler) { 'ovox-compiler01.example.com' }
  let(:agent)    { 'agent07.example.com' }
  let(:crl)      { "-----BEGIN X509 CRL-----\nCA\n-----END X509 CRL-----\n" }
  let(:params)   { { 'server_host' => server, 'compiler_hosts' => compiler, 'certnames' => agent } }

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

  def topology(ca: true, compilers: [compiler], revoked: [])
    { 'certname' => server, 'ca' => ca, 'compilers' => compilers, 'compilers_revoked' => revoked }
  end

  def answers(results, changed = true) # rubocop:disable Style/OptionalBooleanParameter
    { 'action' => 'revoke', 'results' => results, 'changed' => changed }
  end

  def revoked(cleaned: false)
    { 'status' => 'revoked', 'cleaned' => cleaned }
  end

  def installed(target, revoked: false)
    { 'status' => 'updated', 'changed' => true, 'certname' => target, 'path' => '/etc/puppetlabs/puppet/ssl/crl.pem', 'host_cert_revoked' => revoked }
  end

  before(:each) do
    allow_task('ovadm::topology').always_return(topology)
    allow_task('ovadm::ca_expiry').always_return(ca_report)
    allow_task('ovadm::cert_revoke').always_return(answers(agent => revoked))
    allow_task('ovadm::crl_install').return do |targets:, task:, params:| # rubocop:disable Lint/UnusedBlockArgument
      Bolt::ResultSet.new(targets.map { |target| Bolt::Result.new(target, value: installed(target.name)) })
    end
  end

  it 'revokes on the CA, then installs the CRL on the compilers' do
    expect_task('ovadm::cert_revoke').with_targets(server).with_params('certnames' => [agent], 'clean' => false, '_catch_errors' => true)
      .be_called_times(1).always_return(answers(agent => revoked))
    expect_task('ovadm::crl_install').with_targets([compiler]).with_params('crl' => crl, '_catch_errors' => true)
      .be_called_times(1).always_return(installed(compiler))
    expect_out_message.with_params("#{agent}: revoked")
    expect_out_message.with_params("Revocation in force on #{server} and 1 compiler(s).")

    result = run_plan('ovadm::revoke', params)
    expect(result).to be_ok
    expect(result.value['certnames']).to eq(agent => revoked)
    expect(result.value['synced']).to eq(compiler => 'updated')
    expect(result.value['failed']).to eq({})
    expect(result.value['compilers_not_named']).to eq([])
  end

  it 'restarts nothing' do
    expect_task('ovadm::service_restart').not_be_called
    expect_task('ovadm::service_stop').not_be_called

    expect(run_plan('ovadm::revoke', params)).to be_ok
  end

  it 'takes several certnames separated by commas' do
    expect_task('ovadm::cert_revoke').with_params('certnames' => [agent, 'agent08.example.com'], 'clean' => false, '_catch_errors' => true)
      .be_called_times(1).always_return(answers(agent => revoked, 'agent08.example.com' => revoked))

    result = run_plan('ovadm::revoke', params.merge('certnames' => "#{agent},agent08.example.com"))
    expect(result).to be_ok
    expect(result.value['certnames'].keys).to eq([agent, 'agent08.example.com'])
  end

  it 'takes an array of certnames, each once' do
    expect_task('ovadm::cert_revoke').with_params('certnames' => [agent, 'agent08.example.com'], 'clean' => false, '_catch_errors' => true)
      .be_called_times(1).always_return(answers(agent => revoked, 'agent08.example.com' => revoked))

    expect(run_plan('ovadm::revoke', params.merge('certnames' => [agent, 'agent08.example.com', agent]))).to be_ok
  end

  it 'refuses a certname that could be read as an option' do
    expect_task('ovadm::cert_revoke').not_be_called

    expect(run_plan('ovadm::revoke', params.merge('certnames' => '--all'))).not_to be_ok
    expect(run_plan('ovadm::revoke', params.merge('certnames' => ['agent07 example'])).ok?).to be(false)
  end

  it 'passes clean and says the certificate was deleted' do
    expect_task('ovadm::cert_revoke').with_params('certnames' => [agent], 'clean' => true, '_catch_errors' => true)
      .be_called_times(1).always_return(answers(agent => revoked(cleaned: true)))
    expect_out_message.with_params("#{agent}: revoked, and deleted from the CA")

    expect(run_plan('ovadm::revoke', params.merge('clean' => true))).to be_ok
  end

  it 'refuses more than one server' do
    result = run_plan('ovadm::revoke', params.merge('server_host' => [server, compiler]))
    expect(result).not_to be_ok
    expect(result.value.msg).to include('must name one host')
  end

  it 'stops before revoking anything on a host that is not the CA' do
    allow_task('ovadm::topology').always_return(topology(ca: false))
    expect_task('ovadm::cert_revoke').not_be_called

    result = run_plan('ovadm::revoke', params)
    expect(result).not_to be_ok
    expect(result.value.msg).to include('has no CA directory')
  end

  it "refuses the CA server's own certificate, among others too" do
    expect_task('ovadm::cert_revoke').not_be_called
    expect_task('ovadm::crl_install').not_be_called

    result = run_plan('ovadm::revoke', params.merge('certnames' => "#{agent},#{server}"))
    expect(result).not_to be_ok
    expect(result.value.kind).to eq('ovadm/revoke')
    expect(result.value.msg).to eq("#{server} is the certificate of the CA server itself. Revoking it takes the deployment down; nothing was changed.")
  end

  it 'fails with what the task said when nothing could be revoked' do
    expect_task('ovadm::cert_revoke').error_with('msg' => 'puppetserver is not installed on this host, so it is not the CA. Nothing was changed.', 'kind' => 'ovadm/cert-revoke')
    expect_task('ovadm::crl_install').not_be_called

    result = run_plan('ovadm::revoke', params)
    expect(result).not_to be_ok
    expect(result.value.msg).to include('puppetserver is not installed on this host')
  end

  it 'syncs the compilers and then fails when the CA has no certificate of a name' do
    allow_task('ovadm::cert_revoke').always_return(answers(agent => revoked, 'nosuch' => { 'status' => 'not_found', 'cleaned' => false }))
    expect_task('ovadm::crl_install').with_targets([compiler]).be_called_times(1).always_return(installed(compiler))
    expect_out_message.with_params('nosuch: ERROR: the CA has no certificate of that name')

    result = run_plan('ovadm::revoke', params.merge('certnames' => "#{agent},nosuch"))
    expect(result).not_to be_ok
    expect(result.value.msg).to eq('Not finished: the CA did not revoke nosuch.')
    expect(result.value.details['certnames'][agent]).to eq(revoked)
    expect(result.value.details['synced']).to eq(compiler => 'updated')
  end

  it 'fails, naming ovadm::sync_crl, when a compiler did not get the CRL' do
    allow_task('ovadm::crl_install').error_with('msg' => 'Could not write crl.pem (Permission denied). Nothing was changed.', 'kind' => 'ovadm/crl-install')

    result = run_plan('ovadm::revoke', params)
    expect(result).not_to be_ok
    expect(result.value.msg).to eq("Not finished: #{compiler} did not get the CRL and may still serve the revoked hosts; run ovadm::sync_crl for them.")
    expect(result.value.details['certnames']).to eq(agent => revoked)
  end

  it 'says so when the certificate was already revoked, and still syncs the compilers' do
    allow_task('ovadm::cert_revoke').always_return(answers({ agent => { 'status' => 'already_revoked', 'cleaned' => false } }, false))
    expect_task('ovadm::crl_install').with_targets([compiler]).be_called_times(1).always_return(installed(compiler))
    expect_out_message.with_params("#{agent}: was already revoked")

    expect(run_plan('ovadm::revoke', params)).to be_ok
  end

  it 'reports a pending request as nothing to revoke' do
    allow_task('ovadm::cert_revoke').always_return(answers({ agent => { 'status' => 'not_signed', 'cleaned' => false } }, false))
    expect_out_message.with_params("#{agent}: has a pending request and no certificate, so there was nothing to revoke")
    expect_out_message.with_params('No certificate was revoked.')

    expect(run_plan('ovadm::revoke', params)).to be_ok
  end

  context 'without compiler_hosts' do
    let(:params) { { 'server_host' => server, 'certnames' => agent } }

    it 'revokes on the server alone when it knows of no compiler' do
      allow_task('ovadm::topology').always_return(topology(compilers: []))
      expect_task('ovadm::crl_install').not_be_called
      expect_out_message.with_params("Revocation in force on #{server}.")

      result = run_plan('ovadm::revoke', params)
      expect(result).to be_ok
      expect(result.value['synced']).to eq({})
    end

    it 'names the compilers the server knows of' do
      expect_task('ovadm::crl_install').not_be_called

      result = run_plan('ovadm::revoke', params)
      expect(result).to be_ok
      expect(result.value['compilers_not_named']).to eq([compiler])
    end
  end

  context 'when a compiler is revoked' do
    let(:params) { { 'server_host' => server, 'compiler_hosts' => compiler, 'certnames' => compiler } }

    it 'says what that means before and after' do
      allow_task('ovadm::cert_revoke').always_return(answers(compiler => revoked))
      allow_task('ovadm::topology').always_return(topology(revoked: [compiler]))
      allow_task('ovadm::crl_install').always_return(installed(compiler, revoked: true))
      expect_out_message.with_params("#{compiler}: a compiler. Agents refuse a revoked compiler once they have the new CRL, within a day; take it out of the pool first.")
      expect_out_message.with_params(
        "WARNING #{compiler}: its own certificate (#{compiler}) is revoked. Agents refuse it; stop puppetserver there and take it out of the pool.",
      )

      result = run_plan('ovadm::revoke', params)
      expect(result).to be_ok
      expect(result.value['host_cert_revoked']).to eq([compiler])
    end
  end
end
