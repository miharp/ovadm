# frozen_string_literal: true

require 'spec_helper'
require_relative '../support/ca_fixture'

RSpec.describe 'ovadm::cert_revoke task' do
  include CaFixture

  let(:cacrl) { "#{CaFixture::CADIR}/ca_crl.pem" }

  def revoke(certnames, clean: nil)
    params = { 'certnames' => Array(certnames) }
    params['clean'] = clean unless clean.nil?
    run_bolt_task('ovadm::cert_revoke', params)
  end

  context 'without puppetserver' do
    it 'fails and says this host is not the CA' do
      result = revoke('agent07.example.com')
      expect(result.exit_code).to eq(1)
      expect(result.result['_error']).to include('kind' => 'ovadm/cert-revoke')
      expect(result.result['_error']['msg']).to include('puppetserver is not installed on this host')
      expect(result.result).to include('results' => {}, 'changed' => false)
    end
  end

  # The CA's command line stands in for the real one: it answers as
  # `puppetserver ca revoke` and `clean` do, by the first letters of the
  # certname, and for a new revocation writes the CRL as the server would.
  context 'with a CA and its command line' do
    before(:context) do
      link_agent_ruby
      build_ca(layout: 'intermediate', days: 400)
      run_shell(<<~'SH')
        set -e
        mkdir -p /opt/puppetlabs/bin /root/crls
        cat > /opt/puppetlabs/bin/puppetserver <<'STUB'
        #!/bin/bash
        # puppetserver ca <action> --certname <name>
        action="$2"; name="$4"
        echo "$action $name" >> /root/crls/calls
        case "$name" in
          new*)
            cp /root/crls/next.pem /etc/puppetlabs/puppetserver/ca/ca_crl.pem
            echo "Certificate for $name has been revoked"
            [ "$action" = clean ] && echo "Cleaned files related to $name"
            exit 0 ;;
          old*)
            echo "Certificate for $name has been revoked"
            exit 0 ;;
          csr*)
            if [ "$action" = clean ]; then echo "Cleaned files related to $name"; else printf 'Error:\n    Could not revoke unsigned csr for %s\n' "$name"; fi
            exit 24 ;;
          gone*)
            if [ "$action" = clean ]; then printf 'Error:\n    Could not find files to clean for %s\n' "$name"; else printf 'Error:\n    Could not find certificate for %s\n' "$name"; fi
            exit 1 ;;
          *)
            printf "Error:\n    When attempting to revoke certificate '%s', received:\n      code: 500\n      body: Internal Server Error.\n" "$name"
            exit 1 ;;
        esac
        STUB
        sed -i 's/^        //' /opt/puppetlabs/bin/puppetserver
        chmod 0755 /opt/puppetlabs/bin/puppetserver
      SH
      write_crls('/root/crls/next.pem', number: 4, revoked: [7, 9])
    end

    after(:context) do
      run_shell("rm -rf /etc/puppetlabs /opt/puppetlabs/bin/puppetserver #{CaFixture::ORIGINALS} /root/crls")
      unlink_agent_ruby
    end

    before(:each) { run_shell("cp #{CaFixture::ORIGINALS}/ca_crl.pem #{cacrl}; : > /root/crls/calls") }

    def calls
      run_shell('cat /root/crls/calls')['stdout'].lines.map(&:strip)
    end

    it 'revokes a certificate and says the CRL changed' do
      result = revoke('new01.example.com')
      expect(result.exit_code).to eq(0)
      expect(result.result).to eq(
        'action' => 'revoke', 'changed' => true,
        'results' => { 'new01.example.com' => { 'status' => 'revoked', 'cleaned' => false } }
      )
      expect(calls).to eq(['revoke new01.example.com'])
    end

    it 'tells a certificate that was already revoked from one it revoked' do
      result = revoke('old01.example.com')
      expect(result.exit_code).to eq(0)
      expect(result.result).to include('changed' => false)
      expect(result.result['results']).to eq('old01.example.com' => { 'status' => 'already_revoked', 'cleaned' => false })
    end

    it 'answers for each certname, one call each, a name given twice once' do
      result = revoke(%w[new01 old01 csr01 gone01 new01])
      expect(result.exit_code).to eq(0)
      expect(result.result['changed']).to be(true)
      expect(result.result['results']).to eq(
        'new01' => { 'status' => 'revoked', 'cleaned' => false },
        'old01' => { 'status' => 'already_revoked', 'cleaned' => false },
        'csr01' => { 'status' => 'not_signed', 'cleaned' => false },
        'gone01' => { 'status' => 'not_found', 'cleaned' => false },
      )
      expect(calls).to eq(['revoke new01', 'revoke old01', 'revoke csr01', 'revoke gone01'])
    end

    it 'cleans with clean=true: a certificate, a pending request, and not a name the CA does not have' do
      result = revoke(%w[new01 csr01 gone01], clean: true)
      expect(result.exit_code).to eq(0)
      expect(result.result['action']).to eq('clean')
      expect(result.result['results']).to eq(
        'new01' => { 'status' => 'revoked', 'cleaned' => true },
        'csr01' => { 'status' => 'not_signed', 'cleaned' => true },
        'gone01' => { 'status' => 'not_found', 'cleaned' => false },
      )
      expect(calls).to eq(['clean new01', 'clean csr01', 'clean gone01'])
    end

    it 'fails with what the CA said, and still reports the names it did revoke' do
      result = revoke(%w[new01 broken01])
      expect(result.exit_code).to eq(1)
      expect(result.result['results']['new01']).to eq('status' => 'revoked', 'cleaned' => false)
      expect(result.result['results']['broken01']).to include('status' => 'error', 'cleaned' => false)
      expect(result.result['_error']['msg']).to include('puppetserver ca revoke failed for broken01', 'code: 500')
    end

    it "refuses the host's own certname before revoking anything" do
      result = revoke(['new01', certname])
      expect(result.exit_code).to eq(1)
      expect(result.result['_error']['msg']).to eq("#{certname} is this server's own certificate. Revoking it takes the deployment down. Nothing was changed.")
      expect(calls).to eq([])
    end

    it 'refuses a host that has no CA' do
      run_shell("mv #{CaFixture::CADIR}/ca_crt.pem #{CaFixture::CADIR}/ca_crt.pem.aside")
      result = revoke('new01')
      run_shell("mv #{CaFixture::CADIR}/ca_crt.pem.aside #{CaFixture::CADIR}/ca_crt.pem")
      expect(result.exit_code).to eq(1)
      expect(result.result['_error']['msg']).to include('this host is not the CA')
      expect(calls).to eq([])
    end
  end
end
