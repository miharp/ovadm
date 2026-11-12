# frozen_string_literal: true

require 'spec_helper'
require 'time'
require_relative '../support/ca_fixture'

RSpec.describe 'ovadm::ca_extend task' do
  include CaFixture

  let(:cacert) { "#{CaFixture::CADIR}/ca_crt.pem" }
  let(:cacrl)  { "#{CaFixture::CADIR}/ca_crl.pem" }
  let(:infra)  { "#{CaFixture::CADIR}/infra_crl.pem" }
  let(:signed) { "#{CaFixture::CADIR}/signed/#{certname}.pem" }

  def ca_files
    %w[ca_crt.pem ca_crl.pem infra_crl.pem].to_h { |name| [name, sha256("#{CaFixture::CADIR}/#{name}")] }
  end

  def years_from_now(time)
    (Time.parse(time) - Time.now) / (365 * 86_400.0)
  end

  context 'without the agent Ruby' do
    before(:context) { unlink_agent_ruby }

    it 'fails: the host is not a CA' do
      result = run_bolt_task('ovadm::ca_extend')
      expect(result.exit_code).to eq(1)
      expect(result.result['_error']['msg']).to include('/opt/puppetlabs/puppet/bin/ruby is missing')
    end
  end

  context 'with the agent Ruby' do
    before(:context) { link_agent_ruby }
    after(:context) do
      run_shell("rm -rf /etc/puppetlabs #{CaFixture::ORIGINALS}")
      unlink_agent_ruby
    end

    context 'on a root and an intermediate with a year left' do
      before(:context) do
        build_ca(layout: 'intermediate', days: 400)
        @before = { cert: read_pem("#{CaFixture::CADIR}/ca_crt.pem"), crl: read_pem("#{CaFixture::CADIR}/ca_crl.pem") }
        @modes  = run_shell("stat -c '%a %U:%G' #{CaFixture::CADIR}/ca_crt.pem #{CaFixture::CADIR}/ca_crl.pem")['stdout']
        @local  = sha256("#{CaFixture::SSLDIR}/certs/ca.pem")
        @run    = run_bolt_task('ovadm::ca_extend')
      end

      let(:data) { @run.result }

      it 'reports each certificate with its old and new expiry and the key that signed it' do
        expect(@run.exit_code).to eq(0)
        expect(data).to include('status' => 'extended', 'path' => cacert, 'ttl' => '15y', 'warnings' => [])
        expect(data['certificates'].map { |c| [c['subject'], c['role'], File.basename(c['key']), File.basename(c['signed_by']), c['was_expired']] }).to eq(
          [
            ['CN=Puppet CA: fixture', 'intermediate', 'ca_key.pem', 'root_key.pem', false],
            ['CN=Puppet Root CA: fixture', 'root', 'root_key.pem', 'root_key.pem', false],
          ]
        )
        data['certificates'].each do |c|
          expect(c['old_not_after']).to eq(@before[:cert]['certificates'].find { |b| b['subject'] == "/#{c['subject']}" }['not_after'])
          expect(years_from_now(c['new_not_after'])).to be_within(0.01).of(15)
        end
      end

      it 'changes the expiry of each certificate and nothing else about it' do
        after = read_pem(cacert)['certificates']
        expect(after.map { |c| c['subject'] }).to eq(@before[:cert]['certificates'].map { |c| c['subject'] })
        after.zip(@before[:cert]['certificates']).each do |now, was|
          expect(now.reject { |key, _| key == 'not_after' }).to eq(was.reject { |key, _| key == 'not_after' })
          expect(years_from_now(now['not_after'])).to be_within(0.01).of(15)
        end
      end

      it 'leaves a bundle that still verifies a certificate the CA signed before, CRLs included' do
        expect(chain_problems(cacert, signed, cacrl)).to eq([])
      end

      it 're-signs each CRL to run as long as its issuer, with the next number and the same revocations' do
        after = read_pem(cacrl)['crls']
        was   = @before[:crl]['crls']
        expect(after.map { |c| [c['issuer'], c['number'], c['revoked']] }).to eq(
          [['/CN=Puppet CA: fixture', 4, [7]], ['/CN=Puppet Root CA: fixture', 1, []]]
        )
        expect(after.map { |c| c['last_update'] }).to eq(was.map { |c| c['last_update'] })
        expect(after.map { |c| c['extensions'] }).to eq(was.map { |c| c['extensions'] })
        expect(after.map { |c| c['next_update'] }.uniq).to eq(read_pem(cacert)['certificates'].map { |c| c['not_after'] }.uniq)
        expect(read_pem(infra)['crls'].map { |c| c['number'] }).to eq([1, 1])
        expect(data['crls'].map { |c| [File.basename(c['path']), c['crl_number'], c['revoked']] }).to eq(
          [['ca_crl.pem', 4, 1], ['ca_crl.pem', 1, 0], ['infra_crl.pem', 1, 0], ['infra_crl.pem', 1, 0]]
        )
      end

      it 'keeps a copy of every file it replaced, and the owner and mode of each' do
        expect(data['backups'].map { |b| File.basename(b).sub(/\.\d{8}T\d{6}Z\.bak\z/, '') }).to eq(%w[ca_crt.pem ca_crl.pem infra_crl.pem])
        data['backups'].each do |backup|
          expect(sha256(backup)).to eq(sha256("#{CaFixture::ORIGINALS}/#{File.basename(backup).sub(/\.\d{8}T\d{6}Z\.bak\z/, '')}"))
        end
        expect(run_shell("stat -c '%a %U:%G' #{cacert} #{cacrl}")['stdout']).to eq(@modes)
        expect(run_shell("ls #{CaFixture::CADIR} | grep -c ovadm-new || true")['stdout'].strip).to eq('0')
      end

      it 'returns the bundle and the CRLs it wrote, and leaves the host\'s own copy alone' do
        expect(data['bundle']).to eq(run_shell("cat #{cacert}")['stdout'])
        expect(data['crl']).to eq(run_shell("cat #{cacrl}")['stdout'])
        expect(sha256("#{CaFixture::SSLDIR}/certs/ca.pem")).to eq(@local)
      end

      it 'refuses a ttl that would not extend the certificates, and changes nothing' do
        before = ca_files
        result = run_bolt_task('ovadm::ca_extend', { 'ttl' => '30d' })
        expect(result.exit_code).to eq(1)
        expect(result.result['_error']['msg']).to include('CN=Puppet CA: fixture already runs until', 'would not extend', 'Nothing was changed.')
        expect(ca_files).to eq(before)
      end

      it 'refuses a ttl beyond 50 years' do
        result = run_bolt_task('ovadm::ca_extend', { 'ttl' => '51y' })
        expect(result.exit_code).to eq(1)
        expect(result.result['_error']['msg']).to include('longer than 50 years')
      end

      it 'with noop, says what it would do and changes nothing' do
        before = ca_files
        backups = run_shell("ls #{CaFixture::CADIR}")['stdout']
        result = run_bolt_task('ovadm::ca_extend', { 'ttl' => '20y', '_noop' => true })
        expect(result.exit_code).to eq(0)
        value = result.result
        expect(value).to include('status' => 'noop', 'ttl' => '20y', 'backups' => [])
        expect(value).not_to include('bundle', 'crl')
        expect(value['certificates'].map { |c| years_from_now(c['new_not_after']) }).to all(be_within(0.01).of(20))
        expect(ca_files).to eq(before)
        expect(run_shell("ls #{CaFixture::CADIR}")['stdout']).to eq(backups)
      end
    end

    context 'on a single self-signed certificate that has expired' do
      before(:context) do
        build_ca(layout: 'single', days: -3)
        @before = read_pem("#{CaFixture::CADIR}/ca_crt.pem")
      end

      it 'refuses to verify anything before, and verifies it again after' do
        expect(chain_problems(cacert, signed, cacrl)).not_to eq([])

        result = run_bolt_task('ovadm::ca_extend', { 'ttl' => '10y' })
        expect(result.exit_code).to eq(0)
        expect(result.result['certificates'].map { |c| [c['subject'], c['role'], File.basename(c['key']), c['was_expired']] }).to eq(
          [['CN=Puppet CA: fixture', 'root', 'ca_key.pem', true]]
        )
        after = read_pem(cacert)['certificates']
        expect(after[0].reject { |key, _| key == 'not_after' }).to eq(@before['certificates'][0].reject { |key, _| key == 'not_after' })
        expect(years_from_now(after[0]['not_after'])).to be_within(0.01).of(10)
        expect(read_pem(cacrl)['crls'].map { |c| [c['number'], c['revoked']] }).to eq([[4, [7]]])
        expect(chain_problems(cacert, signed, cacrl)).to eq([])
      end
    end

    context 'on a CA whose root key is somewhere else' do
      before(:context) { build_ca(layout: 'intermediate', root_key: false) }

      it 'refuses, says who extends such a CA, and changes nothing' do
        before = ca_files
        result = run_bolt_task('ovadm::ca_extend')
        expect(result.exit_code).to eq(1)
        expect(result.result['_error']['msg']).to include(
          'The private key of CN=Puppet Root CA: fixture is not on this host.', 'puppetserver ca import', 'Nothing was changed.'
        )
        expect(ca_files).to eq(before)
      end
    end

    context 'on a CA whose key does not belong to it' do
      before(:context) do
        build_ca(layout: 'single')
        run_shell("openssl genrsa -out #{CaFixture::CADIR}/ca_key.pem 2048 2>/dev/null || #{CaFixture::AGENT_RUBY} -ropenssl -e 'File.write(\"#{CaFixture::CADIR}/ca_key.pem\", OpenSSL::PKey::RSA.new(2048).to_pem)'")
      end

      it 'refuses' do
        result = run_bolt_task('ovadm::ca_extend')
        expect(result.exit_code).to eq(1)
        expect(result.result['_error']['msg']).to include('Nothing was changed.')
      end
    end

    context 'on a host that is not the CA' do
      before(:context) { run_shell('rm -rf /etc/puppetlabs') }

      it 'fails and says so' do
        result = run_bolt_task('ovadm::ca_extend')
        expect(result.exit_code).to eq(1)
        expect(result.result['_error']['msg']).to include('this host is not the CA')
      end
    end
  end
end
