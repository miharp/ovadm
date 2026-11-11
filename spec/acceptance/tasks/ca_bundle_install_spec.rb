# frozen_string_literal: true

require 'spec_helper'
require_relative '../support/ca_fixture'

RSpec.describe 'ovadm::ca_bundle_install task' do
  include CaFixture

  let(:localcacert) { "#{CaFixture::SSLDIR}/certs/ca.pem" }
  let(:hostcrl)     { "#{CaFixture::SSLDIR}/crl.pem" }
  let(:hostcert)    { "#{CaFixture::SSLDIR}/certs/#{certname}.pem" }
  let(:pdb_ca)      { '/etc/puppetlabs/puppetdb/ssl/ca.pem' }

  def cat(path)
    run_shell("cat #{path}")['stdout']
  end

  # A CA, extended: the host still holds the bundle and CRLs from before.
  def extended_ca(**options)
    build_ca(**options)
    result = run_bolt_task('ovadm::ca_extend')
    raise "ca_extend failed: #{result.result}" unless result.exit_code.zero?

    { 'bundle' => result.result['bundle'], 'crl' => result.result['crl'] }
  end

  context 'without the agent Ruby' do
    before(:context) { unlink_agent_ruby }

    it 'reports not_installed' do
      result = run_bolt_task('ovadm::ca_bundle_install', { 'bundle' => 'x' })
      expect(result.exit_code).to eq(0)
      expect(result.result).to eq('status' => 'not_installed', 'changed' => [])
    end
  end

  context 'with the agent Ruby' do
    before(:context) { link_agent_ruby }
    after(:context) do
      run_shell("rm -rf /etc/puppetlabs #{CaFixture::ORIGINALS}")
      unlink_agent_ruby
    end

    context 'on a host that holds the bundle from before the extension' do
      before(:context) do
        @new = extended_ca(layout: 'intermediate', days: 400)
        run_shell("chmod 0640 #{CaFixture::SSLDIR}/crl.pem")
        @run = run_bolt_task('ovadm::ca_bundle_install', @new)
      end

      it "replaces the host's bundle and CRLs, and reports the host certificate" do
        expect(@run.exit_code).to eq(0)
        expect(@run.result).to include(
          'status' => 'installed', 'certname' => certname, 'changed' => [localcacert, hostcrl],
          'localcacert' => { 'path' => localcacert, 'action' => 'updated' },
          'hostcrl' => { 'path' => hostcrl, 'action' => 'updated' },
          'openvoxdb_ca' => nil
        )
        expect(@run.result['host_cert']).to include('path' => hostcert, 'expired' => false, 'days_left' => be_between(29, 30))
        expect(cat(localcacert)).to eq(@new['bundle'])
        expect(cat(hostcrl)).to eq(@new['crl'])
        expect(chain_problems(localcacert, hostcert, hostcrl)).to eq([])
      end

      it 'keeps the mode of a file it replaces' do
        expect(run_shell("stat -c %a #{hostcrl}")['stdout'].strip).to eq('640')
      end

      it 'changes nothing the second time' do
        result = run_bolt_task('ovadm::ca_bundle_install', @new)
        expect(result.exit_code).to eq(0)
        expect(result.result).to include('status' => 'unchanged', 'changed' => [])
        expect(result.result['localcacert']['action']).to eq('unchanged')
        expect(result.result['hostcrl']['action']).to eq('unchanged')
      end

      it 'leaves the CRLs alone when none are given' do
        run_shell("cp #{CaFixture::ORIGINALS}/ca_crt.pem #{localcacert}")
        result = run_bolt_task('ovadm::ca_bundle_install', { 'bundle' => @new['bundle'] })
        expect(result.result).to include('status' => 'installed', 'changed' => [localcacert], 'hostcrl' => nil)
      end

      it 'does not replace CRLs that are newer than the ones given' do
        old_crl = cat("#{CaFixture::ORIGINALS}/ca_crl.pem")
        result = run_bolt_task('ovadm::ca_bundle_install', { 'bundle' => @new['bundle'], 'crl' => old_crl })
        expect(result.exit_code).to eq(0)
        expect(result.result['hostcrl']).to eq('path' => hostcrl, 'action' => 'kept_newer')
        expect(cat(hostcrl)).to eq(@new['crl'])
      end

      it 'does not create CRLs on a host that keeps none' do
        run_shell("mv #{hostcrl} #{hostcrl}.aside")
        result = run_bolt_task('ovadm::ca_bundle_install', @new)
        run_shell("mv #{hostcrl}.aside #{hostcrl}")
        expect(result.result['hostcrl']).to eq('path' => hostcrl, 'action' => 'absent')
      end

      it "replaces OpenVoxDB's copy where there is one, keeping its owner and mode" do
        run_shell(<<~SH)
          set -e
          install -d /etc/puppetlabs/puppetdb/ssl
          cp #{CaFixture::ORIGINALS}/ca_crt.pem #{pdb_ca}
          chown nobody #{pdb_ca}
          chmod 0600 #{pdb_ca}
        SH
        result = run_bolt_task('ovadm::ca_bundle_install', @new)
        expect(result.result).to include('status' => 'installed', 'changed' => [pdb_ca])
        expect(result.result['openvoxdb_ca']).to eq('path' => pdb_ca, 'action' => 'updated')
        expect(cat(pdb_ca)).to eq(@new['bundle'])
        expect(run_shell("stat -c '%a %U' #{pdb_ca}")['stdout'].strip).to eq('600 nobody')
      end

      it "finds OpenVoxDB's copy where jetty.ini says it is" do
        run_shell(<<~SH)
          set -e
          install -d /etc/puppetlabs/puppetdb/conf.d /opt/pdb
          cp #{CaFixture::ORIGINALS}/ca_crt.pem /opt/pdb/trust.pem
          printf '[jetty]\\nssl-ca-cert = /opt/pdb/trust.pem\\n' > /etc/puppetlabs/puppetdb/conf.d/jetty.ini
        SH
        result = run_bolt_task('ovadm::ca_bundle_install', @new)
        run_shell('rm -rf /etc/puppetlabs/puppetdb/conf.d')
        expect(result.result['openvoxdb_ca']).to eq('path' => '/opt/pdb/trust.pem', 'action' => 'updated')
        expect(cat('/opt/pdb/trust.pem')).to eq(@new['bundle'])
      end
    end

    context 'on a host whose bundle and certificate have both expired' do
      it 'installs the bundle all the same: the certificate still says which CA it belongs to' do
        new = extended_ca(layout: 'single', days: -3, host_days: -3)
        result = run_bolt_task('ovadm::ca_bundle_install', new)
        expect(result.exit_code).to eq(0)
        expect(result.result).to include('status' => 'installed', 'changed' => [localcacert, hostcrl])
        expect(result.result['host_cert']).to include('expired' => true, 'days_left' => be_between(-4, -3))
      end
    end

    context 'given a bundle it should not install' do
      it 'refuses the bundle of another CA, and changes nothing' do
        build_ca(layout: 'intermediate')
        other = { 'bundle' => cat("#{CaFixture::CADIR}/ca_crt.pem"), 'crl' => cat("#{CaFixture::CADIR}/ca_crl.pem") }
        build_ca(layout: 'intermediate')
        before = sha256(localcacert)

        result = run_bolt_task('ovadm::ca_bundle_install', other)
        expect(result.exit_code).to eq(1)
        expect(result.result['_error']['msg']).to include("is not the CA that signed #{hostcert}", 'Nothing was changed.')
        expect(result.result['changed']).to eq([])
        expect(sha256(localcacert)).to eq(before)
      end

      it 'refuses a bundle that has expired' do
        build_ca(layout: 'single', days: -3)
        result = run_bolt_task('ovadm::ca_bundle_install', { 'bundle' => cat("#{CaFixture::CADIR}/ca_crt.pem") })
        expect(result.exit_code).to eq(1)
        expect(result.result['_error']['msg']).to include('CN=Puppet CA: fixture in the bundle given expired on')
      end

      it 'refuses a bundle without the root its certificates lead to' do
        build_ca(layout: 'intermediate')
        first = cat("#{CaFixture::CADIR}/ca_crt.pem")[/-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----\n/m]
        result = run_bolt_task('ovadm::ca_bundle_install', { 'bundle' => first })
        expect(result.exit_code).to eq(1)
        expect(result.result['_error']['msg']).to include('CN=Puppet CA: fixture in the bundle given is not signed by a certificate in it')
      end

      it 'refuses CRLs that the bundle did not issue' do
        build_ca(layout: 'intermediate')
        foreign = cat("#{CaFixture::CADIR}/ca_crl.pem")
        build_ca(layout: 'intermediate')
        result = run_bolt_task('ovadm::ca_bundle_install', { 'bundle' => cat("#{CaFixture::CADIR}/ca_crt.pem"), 'crl' => foreign })
        expect(result.exit_code).to eq(1)
        expect(result.result['_error']['msg']).to include('is not signed by a certificate in the bundle')
      end

      it 'refuses text that holds no certificate' do
        result = run_bolt_task('ovadm::ca_bundle_install', { 'bundle' => 'not a certificate' })
        expect(result.exit_code).to eq(1)
        expect(result.result['_error']['msg']).to include('holds no certificate')
      end
    end

    context 'on a host that never enrolled' do
      it 'reports not_enrolled and writes nothing' do
        build_ca(layout: 'intermediate')
        bundle = cat("#{CaFixture::CADIR}/ca_crt.pem")
        run_shell("rm -rf #{CaFixture::SSLDIR}")
        result = run_bolt_task('ovadm::ca_bundle_install', { 'bundle' => bundle })
        expect(result.exit_code).to eq(0)
        expect(result.result).to include('status' => 'not_enrolled', 'changed' => [])
        expect(run_shell("test -e #{localcacert}")['exit_code']).not_to eq(0)
      end
    end
  end
end
