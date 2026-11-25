# frozen_string_literal: true

require 'spec_helper'
require_relative '../support/ca_fixture'

RSpec.describe 'ovadm::crl_install task' do
  include CaFixture

  let(:localcacert) { "#{CaFixture::SSLDIR}/certs/ca.pem" }
  let(:hostcrl)     { "#{CaFixture::SSLDIR}/crl.pem" }
  let(:signer)      { 'CN=Puppet CA: fixture' }

  def cat(path)
    run_shell("cat #{path}")['stdout']
  end

  # The signing CA's CRL as the task describes it, first of the two.
  def signing(crls)
    crls.find { |crl| crl['issuer'] == 'CN=Puppet CA: fixture' }
  end

  context 'without the agent Ruby' do
    before(:context) { unlink_agent_ruby }

    it 'reports not_installed' do
      result = run_bolt_task('ovadm::crl_install', { 'crl' => 'x' })
      expect(result.exit_code).to eq(0)
      expect(result.result).to eq('status' => 'not_installed', 'changed' => false)
    end
  end

  context 'with the agent Ruby' do
    before(:context) { link_agent_ruby }
    after(:context) do
      run_shell("rm -rf /etc/puppetlabs #{CaFixture::ORIGINALS} /root/crls")
      unlink_agent_ruby
    end

    # The host holds the CRLs from before a revocation (number 3, serial 7
    # revoked); the CA has since revoked serial 9.
    context 'on a host whose copy is behind the CA' do
      before(:context) do
        build_ca(layout: 'intermediate', days: 400)
        run_shell("mkdir -p /root/crls && chmod 0640 #{CaFixture::SSLDIR}/crl.pem && chown nobody #{CaFixture::SSLDIR}/crl.pem")
        @newer = write_crls('/root/crls/newer.pem', number: 4, revoked: [7, 9])
        @run = run_bolt_task('ovadm::crl_install', { 'crl' => @newer })
      end

      it "replaces the host's CRLs and says what was there and what is there now" do
        expect(@run.exit_code).to eq(0)
        expect(@run.result).to include('status' => 'updated', 'changed' => true, 'certname' => certname, 'path' => hostcrl, 'host_cert_revoked' => false)
        expect(signing(@run.result['previous'])).to include('crl_number' => 3, 'revoked' => 1)
        expect(signing(@run.result['crls'])).to include('crl_number' => 4, 'revoked' => 2, 'expired' => false)
        expect(@run.result['crls'].map { |crl| crl['issuer'] }).to eq([signer, 'CN=Puppet Root CA: fixture'])
        expect(cat(hostcrl)).to eq(@newer)
        expect(chain_problems(localcacert, "#{CaFixture::SSLDIR}/certs/#{certname}.pem", hostcrl)).to eq([])
      end

      it 'keeps the owner and mode of the file it replaces, and leaves no file beside it' do
        expect(run_shell("stat -c '%a %U' #{hostcrl}")['stdout'].strip).to eq('640 nobody')
        expect(run_shell("ls #{CaFixture::SSLDIR}")['stdout'].split).to contain_exactly('certs', 'crl.pem')
      end

      it 'changes nothing the second time' do
        before = run_shell("stat -c %Y #{hostcrl}")['stdout']
        result = run_bolt_task('ovadm::crl_install', { 'crl' => @newer })
        expect(result.exit_code).to eq(0)
        expect(result.result).to include('status' => 'unchanged', 'changed' => false)
        expect(run_shell("stat -c %Y #{hostcrl}")['stdout']).to eq(before)
      end

      it 'keeps CRLs that are newer than the ones given' do
        older = cat("#{CaFixture::ORIGINALS}/ca_crl.pem")
        result = run_bolt_task('ovadm::crl_install', { 'crl' => older })
        expect(result.exit_code).to eq(0)
        expect(result.result).to include('status' => 'kept_newer', 'changed' => false)
        expect(cat(hostcrl)).to eq(@newer)
      end

      it "says when the host's own certificate is on the list" do
        own = write_crls('/root/crls/own.pem', number: 5, revoked: [5, 7, 9])
        result = run_bolt_task('ovadm::crl_install', { 'crl' => own })
        expect(result.result).to include('status' => 'updated', 'host_cert_revoked' => true)
      end

      it 'replaces a copy that has run out with the same CRL number' do
        write_crls('/root/crls/ran-out.pem', number: 6, revoked: [7], days: -1)
        run_shell("cat /root/crls/ran-out.pem > #{hostcrl}")
        current = write_crls('/root/crls/current.pem', number: 6, revoked: [7])
        result = run_bolt_task('ovadm::crl_install', { 'crl' => current })
        expect(result.result).to include('status' => 'updated', 'changed' => true)
        expect(signing(result.result['previous'])).to include('crl_number' => 6, 'expired' => true)
        expect(cat(hostcrl)).to eq(current)
      end

      it 'replaces a file that holds no CRL' do
        current = cat(hostcrl)
        run_shell("echo garbage > #{hostcrl}")
        result = run_bolt_task('ovadm::crl_install', { 'crl' => current })
        expect(result.result).to include('status' => 'updated', 'previous' => [])
        expect(cat(hostcrl)).to eq(current)
      end

      it 'does not create CRLs on a host that keeps none' do
        current = cat(hostcrl)
        run_shell("mv #{hostcrl} #{hostcrl}.aside")
        result = run_bolt_task('ovadm::crl_install', { 'crl' => current })
        exists = run_shell("test -e #{hostcrl}")['exit_code']
        run_shell("mv #{hostcrl}.aside #{hostcrl}")
        expect(result.exit_code).to eq(0)
        expect(result.result).to include('status' => 'absent', 'changed' => false)
        expect(exists).not_to eq(0)
      end
    end

    context 'with CRLs it must not install' do
      before(:context) do
        build_ca(layout: 'intermediate', days: 400)
        run_shell('mkdir -p /root/crls')
        @before = sha256("#{CaFixture::SSLDIR}/crl.pem")
      end

      after(:each) { expect(sha256(hostcrl)).to eq(@before) }

      it 'refuses a CRL signed by a key the host does not trust' do
        foreign = write_crls('/root/crls/foreign.pem', number: 9, revoked: [], foreign: true)
        result = run_bolt_task('ovadm::crl_install', { 'crl' => foreign })
        expect(result.exit_code).to eq(1)
        expect(result.result['_error']).to include('kind' => 'ovadm/crl-install')
        expect(result.result['_error']['msg']).to include("The CRL of #{signer} given is not signed by a certificate in #{localcacert}", 'Nothing was changed.')
      end

      it 'refuses a CRL that has run out' do
        ran_out = write_crls('/root/crls/ran-out.pem', number: 9, revoked: [], days: -1)
        result = run_bolt_task('ovadm::crl_install', { 'crl' => ran_out })
        expect(result.exit_code).to eq(1)
        expect(result.result['_error']['msg']).to include("The CRL of #{signer} given ran out on", 'Nothing was changed.')
      end

      it 'refuses text that holds no CRL' do
        result = run_bolt_task('ovadm::crl_install', { 'crl' => cat(localcacert) })
        expect(result.exit_code).to eq(1)
        expect(result.result['_error']['msg']).to eq('The CRLs given hold no CRL. Nothing was changed.')
      end

      it 'reports not_enrolled on a host that trusts no CA' do
        current = cat("#{CaFixture::CADIR}/ca_crl.pem")
        run_shell("mv #{localcacert} #{localcacert}.aside")
        result = run_bolt_task('ovadm::crl_install', { 'crl' => current })
        run_shell("mv #{localcacert}.aside #{localcacert}")
        expect(result.exit_code).to eq(0)
        expect(result.result).to include('status' => 'not_enrolled', 'changed' => false, 'detail' => "#{localcacert} does not exist")
      end
    end

    context 'on a host with a single self-signed CA' do
      before(:context) do
        build_ca(layout: 'single', days: 400)
        run_shell('mkdir -p /root/crls')
      end

      it 'installs the one CRL' do
        newer = write_crls('/root/crls/single.pem', number: 4, revoked: [7, 9])
        result = run_bolt_task('ovadm::crl_install', { 'crl' => newer })
        expect(result.result).to include('status' => 'updated', 'changed' => true)
        expect(result.result['crls'].map { |crl| [crl['issuer'], crl['crl_number'], crl['revoked']] }).to eq([[signer, 4, 2]])
        expect(cat(hostcrl)).to eq(newer)
      end
    end
  end
end
