# frozen_string_literal: true

require 'json'

# A CA made in the acceptance container, laid out as puppetserver lays one
# out, for the tasks that read and re-sign it. The distribution's Ruby stands
# in for the agent's, linked where the tasks look for it.
module CaFixture
  AGENT_RUBY = '/opt/puppetlabs/puppet/bin/ruby'
  CADIR      = '/etc/puppetlabs/puppetserver/ca'
  SSLDIR     = '/etc/puppetlabs/puppet/ssl'
  ORIGINALS  = '/root/ca-originals'

  def link_agent_ruby
    out = run_shell(<<~SH)
      set -e
      if ! command -v ruby >/dev/null; then
        if command -v apt-get >/dev/null; then
          apt-get update -qq
          DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ruby >/dev/null
        else
          dnf install -y -q ruby rubygem-json
        fi
      fi
      if [ ! -e #{AGENT_RUBY} ]; then
        mkdir -p #{File.dirname(AGENT_RUBY)}
        ln -s "$(command -v ruby)" #{AGENT_RUBY}
      fi
    SH
    raise "could not set up Ruby in the container: #{out}" unless out['exit_code']&.zero?
  end

  def unlink_agent_ruby
    run_shell("if [ -L #{AGENT_RUBY} ]; then rm -f #{AGENT_RUBY}; fi")
  end

  def container_ruby(script, env = {})
    assignments = env.map { |key, value| "#{key}=#{Shellwords.escape(value.to_s)}" }.join(' ')
    out = run_shell("#{assignments} #{AGENT_RUBY} - <<'CA_FIXTURE_RB'\n#{script}\nCA_FIXTURE_RB\n")
    raise "Ruby in the container failed: #{out}" unless out['exit_code']&.zero?

    out['stdout']
  end

  # Replaces /etc/puppetlabs with a CA and one enrolled host, this one.
  #
  # layout:    'intermediate' (root + signing certificate) or 'single'
  # days:      how long the CA certificates and their CRLs still run; negative
  #            for a CA that has expired
  # root_key:  false leaves root_key.pem out, as with an externally issued CA
  # host_days: how long the host's own certificate still runs
  def build_ca(layout: 'intermediate', days: 400, root_key: true, host_days: 30)
    container_ruby(<<~'RB', 'LAYOUT' => layout, 'DAYS' => days, 'ROOT_KEY' => root_key, 'HOST_DAYS' => host_days, 'CADIR' => CADIR, 'SSLDIR' => SSLDIR, 'ORIGINALS' => ORIGINALS)
      require 'fileutils'
      require 'openssl'
      require 'socket'

      cadir, ssldir, originals = ENV.values_at('CADIR', 'SSLDIR', 'ORIGINALS')
      FileUtils.rm_rf(['/etc/puppetlabs', originals])
      FileUtils.mkdir_p(["#{cadir}/signed", "#{ssldir}/certs"])

      now        = Time.now
      not_before = now - (600 * 86_400)
      not_after  = now + (ENV['DAYS'].to_i * 86_400)
      digest     = OpenSSL::Digest.new('SHA256')

      certificate = lambda do |subject, key, issuer, issuer_key, serial, ends, ca|
        cert = OpenSSL::X509::Certificate.new
        cert.version    = 2
        cert.serial     = serial
        cert.subject    = OpenSSL::X509::Name.parse(subject)
        cert.issuer     = issuer ? issuer.subject : cert.subject
        cert.public_key = key
        cert.not_before = not_before
        cert.not_after  = ends
        factory = OpenSSL::X509::ExtensionFactory.new
        factory.subject_certificate = cert
        factory.issuer_certificate  = issuer || cert
        cert.add_extension(factory.create_extension('basicConstraints', ca ? 'CA:TRUE' : 'CA:FALSE', true))
        cert.add_extension(factory.create_extension('keyUsage', 'keyCertSign, cRLSign', true)) if ca
        cert.add_extension(factory.create_extension('subjectKeyIdentifier', 'hash'))
        cert.add_extension(factory.create_extension('authorityKeyIdentifier', 'keyid:always'))
        cert.add_extension(factory.create_extension('nsComment', 'Puppet Server Internal Certificate'))
        cert.sign(issuer_key || key, digest)
        cert
      end

      crl_for = lambda do |issuer, key, number, revoked|
        crl = OpenSSL::X509::CRL.new
        crl.version     = 1
        crl.issuer      = issuer.subject
        crl.last_update = not_before
        crl.next_update = not_after
        revoked.each do |serial|
          entry = OpenSSL::X509::Revoked.new
          entry.serial = serial
          entry.time   = now - 3600
          crl.add_revoked(entry)
        end
        factory = OpenSSL::X509::ExtensionFactory.new
        factory.issuer_certificate = issuer
        crl.add_extension(factory.create_extension('authorityKeyIdentifier', 'keyid:always'))
        crl.add_extension(OpenSSL::X509::Extension.new('crlNumber', OpenSSL::ASN1::Integer(number)))
        crl.sign(key, digest)
        crl
      end

      root_key = OpenSSL::PKey::RSA.new(2048)
      if ENV['LAYOUT'] == 'single'
        root = certificate.call('/CN=Puppet CA: fixture', root_key, nil, nil, 1, not_after, true)
        signer, signer_key = root, root_key
        bundle = [root]
        crls   = [crl_for.call(root, root_key, 3, [7])]
        infra  = [crl_for.call(root, root_key, 0, [])]
      else
        root = certificate.call('/CN=Puppet Root CA: fixture', root_key, nil, nil, 1, not_after, true)
        signer_key = OpenSSL::PKey::RSA.new(2048)
        signer = certificate.call('/CN=Puppet CA: fixture', signer_key, root, root_key, 2, not_after, true)
        bundle = [signer, root]
        root_crl = crl_for.call(root, root_key, 0, [])
        crls   = [crl_for.call(signer, signer_key, 3, [7]), root_crl]
        infra  = [crl_for.call(signer, signer_key, 0, []), root_crl]
        File.write("#{cadir}/root_key.pem", root_key.to_pem) if ENV['ROOT_KEY'] == 'true'
      end

      certname = Socket.gethostname
      host_key = OpenSSL::PKey::RSA.new(2048)
      host = certificate.call("/CN=#{certname}", host_key, signer, signer_key, 5, now + (ENV['HOST_DAYS'].to_i * 86_400), false)

      File.write("#{cadir}/ca_crt.pem", bundle.map(&:to_pem).join)
      File.write("#{cadir}/ca_key.pem", signer_key.to_pem)
      File.write("#{cadir}/ca_crl.pem", crls.map(&:to_pem).join)
      File.write("#{cadir}/infra_crl.pem", infra.map(&:to_pem).join)
      File.write("#{cadir}/signed/#{certname}.pem", host.to_pem)
      FileUtils.chmod(0o640, Dir["#{cadir}/*.pem"])
      File.write("#{ssldir}/certs/ca.pem", bundle.map(&:to_pem).join)
      File.write("#{ssldir}/certs/#{certname}.pem", host.to_pem)
      File.write("#{ssldir}/crl.pem", crls.map(&:to_pem).join)
      FileUtils.mkdir_p(originals)
      FileUtils.cp(Dir["#{cadir}/*.pem"], originals, preserve: true)
    RB
  end

  # The certificates and CRLs in a PEM file, as data to compare.
  def read_pem(path)
    JSON.parse(container_ruby(<<~'RB', 'PEM' => path))
      require 'json'
      require 'openssl'
      require 'time'

      text = File.read(ENV['PEM'])
      certs = text.scan(/-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----/m).map do |pem|
        cert = OpenSSL::X509::Certificate.new(pem)
        {
          'subject'    => cert.subject.to_s,
          'issuer'     => cert.issuer.to_s,
          'serial'     => cert.serial.to_i,
          'not_before' => cert.not_before.utc.iso8601,
          'not_after'  => cert.not_after.utc.iso8601,
          'public_key' => OpenSSL::Digest.new('SHA256').hexdigest(cert.public_key.to_der),
          'extensions' => cert.extensions.map { |ext| [ext.oid, ext.value, ext.critical?] },
          'algorithm'  => cert.signature_algorithm,
        }
      end
      crls = text.scan(/-----BEGIN X509 CRL-----.+?-----END X509 CRL-----/m).map do |pem|
        crl = OpenSSL::X509::CRL.new(pem)
        number = crl.extensions.find { |ext| ext.oid == 'crlNumber' }
        {
          'issuer'      => crl.issuer.to_s,
          'last_update' => crl.last_update.utc.iso8601,
          'next_update' => crl.next_update.utc.iso8601,
          'number'      => number && number.value.to_i,
          'revoked'     => crl.revoked.map { |entry| entry.serial.to_i },
          'extensions'  => crl.extensions.map(&:oid),
        }
      end
      puts JSON.generate('certificates' => certs, 'crls' => crls)
    RB
  end

  # Whether every certificate and CRL in the files chains to the bundle, at
  # the current time: what an agent checks on each connection.
  def chain_problems(bundle_path, cert_path, crl_path)
    JSON.parse(container_ruby(<<~'RB', 'BUNDLE' => bundle_path, 'CERT' => cert_path, 'CRL' => crl_path))
      require 'json'
      require 'openssl'

      store = OpenSSL::X509::Store.new
      File.read(ENV['BUNDLE']).scan(/-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----/m).each do |pem|
        store.add_cert(OpenSSL::X509::Certificate.new(pem))
      end
      File.read(ENV['CRL']).scan(/-----BEGIN X509 CRL-----.+?-----END X509 CRL-----/m).each do |pem|
        store.add_crl(OpenSSL::X509::CRL.new(pem))
      end
      store.flags = OpenSSL::X509::V_FLAG_CRL_CHECK | OpenSSL::X509::V_FLAG_CRL_CHECK_ALL
      cert = OpenSSL::X509::Certificate.new(File.read(ENV['CERT']))
      puts JSON.generate(store.verify(cert) ? [] : [store.error_string])
    RB
  end

  def sha256(path)
    run_shell("sha256sum #{path}")['stdout'].split.first
  end

  def certname
    @certname ||= run_shell('hostname')['stdout'].strip
  end
end
