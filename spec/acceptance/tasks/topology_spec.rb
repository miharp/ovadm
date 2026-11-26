# frozen_string_literal: true

require 'spec_helper'
require_relative '../support/ca_fixture'

RSpec.describe 'ovadm::topology task' do
  let(:result) { run_bolt_task('ovadm::topology', {}) }

  it 'succeeds and reports the fields the status plan reads' do
    expect(result.exit_code).to eq(0)
    expect(result.result).to include('certname', 'ca', 'server_role', 'compilers', 'compilers_revoked', 'openvoxdb', 'postgresql')
    expect(result.result['openvoxdb']).to include('server_urls', 'version', 'database')
    expect(result.result['postgresql']).to include('version', 'pg_dump')
  end

  it 'reports the certname and no compilers on a lone server' do
    expect(result.result['certname']).not_to be_empty
    expect(result.result['compilers']).to eq([])
    expect(result.result['compilers_revoked']).to eq([])
    expect([true, false]).to include(result.result['ca'])
  end

  # Compilers are the signed certificates that carry pp_role=openvox_compiler.
  # A revoked one stays in signed/ until it is cleaned.
  context 'on a CA that has signed compilers' do
    include CaFixture

    before(:context) do
      link_agent_ruby
      build_ca(layout: 'intermediate', days: 400)
      sign_host('compiler01.example.com', serial: 2587, pp_role: 'openvox_compiler')
      sign_host('compiler02.example.com', serial: 8, pp_role: 'openvox_compiler')
      sign_host('agent01.example.com', serial: 7, pp_role: 'webserver')
      write_crls("#{CaFixture::CADIR}/ca_crl.pem", number: 4, revoked: [7, 2587])
    end

    after(:context) do
      run_shell("rm -rf /etc/puppetlabs #{CaFixture::ORIGINALS}")
      unlink_agent_ruby
    end

    it 'lists the compilers, and which of them are revoked' do
      expect(result.result).to include(
        'ca' => true,
        'compilers' => ['compiler01.example.com', 'compiler02.example.com'],
        'compilers_revoked' => ['compiler01.example.com'],
      )
    end

    it 'reports none revoked when the CA has no CRL to read' do
      run_shell("mv #{CaFixture::CADIR}/ca_crl.pem #{CaFixture::CADIR}/ca_crl.pem.aside")
      report = run_bolt_task('ovadm::topology', {}).result
      run_shell("mv #{CaFixture::CADIR}/ca_crl.pem.aside #{CaFixture::CADIR}/ca_crl.pem")
      expect(report['compilers']).to eq(['compiler01.example.com', 'compiler02.example.com'])
      expect(report['compilers_revoked']).to eq([])
    end
  end
end
