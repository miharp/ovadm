# frozen_string_literal: true

require 'spec_helper'
require_relative '../support/ca_fixture'

RSpec.describe 'ovadm::ca_expiry task' do
  include CaFixture

  context 'without the agent Ruby' do
    before(:context) { unlink_agent_ruby }

    it 'reports not_installed and nothing else' do
      result = run_bolt_task('ovadm::ca_expiry')
      expect(result.exit_code).to eq(0)
      expect(result.result).to include('status' => 'not_installed', 'ca' => nil, 'local_ca' => nil, 'host_cert' => nil)
    end
  end

  context 'with the agent Ruby' do
    before(:context) { link_agent_ruby }
    after(:context) do
      run_shell('rm -rf /etc/puppetlabs')
      unlink_agent_ruby
    end

    context 'on a CA with a root and an intermediate' do
      before(:context) { build_ca(layout: 'intermediate', days: 400, host_days: 30) }

      let(:data) { run_bolt_task('ovadm::ca_expiry').result }

      it 'describes each certificate, its role and the key it belongs to' do
        ca = data['ca']
        expect(data['status']).to eq('ok')
        expect(ca).to include('path' => "#{CaFixture::CADIR}/ca_crt.pem", 'layout' => 'intermediate', 'extendable' => true, 'problems' => [])
        expect(ca['certificates'].map { |c| [c['subject'], c['role'], c['key']] }).to eq(
          [
            ['CN=Puppet CA: fixture', 'intermediate', "#{CaFixture::CADIR}/ca_key.pem"],
            ['CN=Puppet Root CA: fixture', 'root', "#{CaFixture::CADIR}/root_key.pem"],
          ]
        )
        expect(ca['certificates'].map { |c| c['days_left'] }).to all(be_between(399, 400))
        expect(ca['certificates'].map { |c| c['expired'] }).to all(be(false))
        expect(ca).to include('days_left' => be_between(399, 400), 'expired' => false)
        expect(ca).not_to include('bundle', 'crl')
      end

      it 'lists the CRLs of both files with their numbers and revocations' do
        crls = data['ca']['crls']
        expect(crls.map { |c| [File.basename(c['path']), c['issuer'], c['crl_number'], c['revoked']] }).to eq(
          [
            ['ca_crl.pem', 'CN=Puppet CA: fixture', 3, 1],
            ['ca_crl.pem', 'CN=Puppet Root CA: fixture', 0, 0],
            ['infra_crl.pem', 'CN=Puppet CA: fixture', 0, 0],
            ['infra_crl.pem', 'CN=Puppet Root CA: fixture', 0, 0],
          ]
        )
        expect(crls.map { |c| c['expired'] }).to all(be(false))
      end

      it "reports the host's copy of the CA, its CRLs and its own certificate" do
        expect(data['certname']).to eq(certname)
        expect(data['local_ca']).to include('path' => "#{CaFixture::SSLDIR}/certs/ca.pem", 'matches_ca' => true, 'expired' => false)
        expect(data['host_crl']).to include('path' => "#{CaFixture::SSLDIR}/crl.pem", 'expired' => false)
        expect(data['host_cert']).to include(
          'path' => "#{CaFixture::SSLDIR}/certs/#{certname}.pem", 'subject' => "CN=#{certname}",
          'signed_by_local_ca' => true, 'expired' => false, 'days_left' => be_between(29, 30)
        )
        expect(data['openvoxdb_ca']).to be_nil
      end

      it 'returns the bundle and the CRLs when asked' do
        ca = run_bolt_task('ovadm::ca_expiry', { 'include_bundle' => true }).result['ca']
        expect(ca['bundle']).to eq(run_shell("cat #{CaFixture::CADIR}/ca_crt.pem")['stdout'])
        expect(ca['crl']).to eq(run_shell("cat #{CaFixture::CADIR}/ca_crl.pem")['stdout'])
      end

      it "says when the host's copy is not the CA directory's, and when OpenVoxDB's is not the host's" do
        run_shell(<<~SH)
          set -e
          sed -n '/BEGIN/,/END/p;/END/q' #{CaFixture::CADIR}/ca_crt.pem > #{CaFixture::SSLDIR}/certs/ca.pem
          install -d /etc/puppetlabs/puppetdb/ssl
          cp #{CaFixture::CADIR}/ca_crt.pem /etc/puppetlabs/puppetdb/ssl/ca.pem
        SH
        expect(data['local_ca']['matches_ca']).to be(false)
        expect(data['openvoxdb_ca']).to include('path' => '/etc/puppetlabs/puppetdb/ssl/ca.pem', 'matches_local' => false)
      end
    end

    context 'on a CA whose root key is somewhere else' do
      before(:context) { build_ca(layout: 'intermediate', root_key: false) }

      it 'says the CA cannot be extended here, and why' do
        ca = run_bolt_task('ovadm::ca_expiry').result['ca']
        expect(ca['extendable']).to be(false)
        expect(ca['problems']).to eq(['the private key of CN=Puppet Root CA: fixture is not on this host: an externally issued CA is extended by its owner'])
        expect(ca['certificates'].map { |c| c['key'] }).to eq(["#{CaFixture::CADIR}/ca_key.pem", nil])
      end
    end

    context 'on a single self-signed CA that has expired' do
      before(:context) { build_ca(layout: 'single', days: -3, host_days: -3) }

      it 'reports the layout, and that the CA, its CRLs and the host certificate have expired' do
        data = run_bolt_task('ovadm::ca_expiry').result
        expect(data['ca']).to include('layout' => 'single', 'extendable' => true, 'expired' => true, 'days_left' => be_between(-4, -3))
        expect(data['ca']['certificates'].map { |c| [c['role'], c['expired']] }).to eq([['root', true]])
        expect(data['ca']['crls'].map { |c| c['expired'] }).to all(be(true))
        expect(data['local_ca']).to include('expired' => true, 'matches_ca' => true)
        expect(data['host_cert']).to include('expired' => true, 'signed_by_local_ca' => true)
      end
    end

    context 'on a host that is not the CA' do
      before(:context) do
        build_ca
        run_shell("rm -rf #{CaFixture::CADIR}")
      end

      it "reports no CA, and the host's copy with nothing to compare it to" do
        data = run_bolt_task('ovadm::ca_expiry').result
        expect(data['ca']).to be_nil
        expect(data['local_ca']).to include('matches_ca' => nil, 'expired' => false)
        expect(data['local_ca']['certificates'].length).to eq(2)
        expect(data['host_cert']['signed_by_local_ca']).to be(true)
      end
    end
  end
end
