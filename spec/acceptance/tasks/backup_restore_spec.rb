# frozen_string_literal: true

require 'spec_helper'
require 'json'

# A primary laid out by hand (no OpenVox in the container), backed up with
# backup_create, changed, and put back. The manifest records no package
# versions, which is what the host has too, so the version check passes.
RSpec.describe 'ovadm::backup_restore task' do
  let(:destination) { '/var/backups/openvox' }
  let(:cadir) { '/etc/puppetlabs/puppetserver/ca' }

  def seed_primary
    run_shell(<<~SH)
      set -e
      rm -rf /etc/puppetlabs #{'/var/backups/openvox'} /root/.ssh/deploy_key
      install -d -m 0750 #{'/etc/puppetlabs/puppetserver/ca'} #{'/etc/puppetlabs/puppetserver/ca/signed'}
      echo CAKEY > #{'/etc/puppetlabs/puppetserver/ca/ca_key.pem'}; chmod 0640 #{'/etc/puppetlabs/puppetserver/ca/ca_key.pem'}
      echo CACRT > #{'/etc/puppetlabs/puppetserver/ca/ca_crt.pem'}
      printf '0x0003\\n' > #{'/etc/puppetlabs/puppetserver/ca/serial'}
      printf '0x0001 2026-10-01T00:00:00UTC 2031-10-01T00:00:00UTC /CN=host\\n0x0002 2026-10-01T00:00:00UTC 2031-10-01T00:00:00UTC /CN=agent01.example.com\\n' > #{'/etc/puppetlabs/puppetserver/ca/inventory.txt'}
      echo AGENTCRT > #{'/etc/puppetlabs/puppetserver/ca/signed/agent01.example.com.pem'}
      chown -R 65534:65534 #{'/etc/puppetlabs/puppetserver/ca'}
      install -d /etc/puppetlabs/puppet/ssl/private_keys /etc/puppetlabs/puppetserver/conf.d /etc/puppetlabs/puppetdb/conf.d
      echo HOSTKEY > /etc/puppetlabs/puppet/ssl/private_keys/host.pem; chmod 0600 /etc/puppetlabs/puppet/ssl/private_keys/host.pem
      printf '[main]\\ncertname = host\\n' > /etc/puppetlabs/puppet/puppet.conf
      echo 'webserver: { good: true }' > /etc/puppetlabs/puppetserver/conf.d/webserver.conf
      echo 'autosign' > /etc/puppetlabs/puppet/autosign.conf
      printf '[database]\\nsubname = //localhost:5432/puppetdb\\n' > /etc/puppetlabs/puppetdb/conf.d/database.ini
      install -d /etc/puppetlabs/code/environments/production/manifests
      echo 'node default {}' > /etc/puppetlabs/code/environments/production/manifests/site.pp
      echo '{"name":"production","signature":"abc123"}' > /etc/puppetlabs/code/environments/production/.r10k-deploy.json
      install -d -m 0700 /root/.ssh; echo DEPLOYKEY > /root/.ssh/deploy_key; chmod 0600 /root/.ssh/deploy_key
      install -d /etc/puppetlabs/r10k; printf ':cachedir: /var/cache/r10k\n' > /etc/puppetlabs/r10k/r10k.yaml
    SH
  end

  def backup(params = {})
    result = run_bolt_task('ovadm::backup_create', params)
    raise "backup_create failed: #{result.result}" unless result.exit_code.zero?

    result.result['archive']
  end

  def restore(params)
    run_bolt_task('ovadm::backup_restore', params)
  end

  def cat(path)
    run_shell("cat #{path}")['stdout']
  end

  before { seed_primary }

  context 'after configuration changed' do
    it 'puts the archived files back with owners and modes, reports what changed, and leaves added files alone' do
      archive = backup('extra_paths' => '/root/.ssh/deploy_key')
      run_shell(<<~SH)
        echo 'webserver: { bad: true }' > /etc/puppetlabs/puppetserver/conf.d/webserver.conf
        rm /etc/puppetlabs/puppet/autosign.conf
        echo 'added' > /etc/puppetlabs/puppetserver/conf.d/added.conf
        echo 'leftover' > /etc/puppetlabs/puppet/puppet.conf.rpmnew
        chmod 0644 /etc/puppetlabs/puppetserver/ca/ca_key.pem; chown 0:0 /etc/puppetlabs/puppetserver/ca/ca_key.pem
      SH
      result = restore('archive' => archive)
      expect(result.exit_code).to eq(0)
      data = result.result
      expect(data['status']).to eq('restored')
      expect(data['scope']).to eq(%w[ca config code extra])
      expect(data['changed']).to eq(['/etc/puppetlabs/puppetserver/conf.d/webserver.conf'])
      expect(data['missing']).to eq(['/etc/puppetlabs/puppet/autosign.conf'])
      expect(data['unchanged']).to eq(data['in_scope'] - 2)
      expect(data['ca']).to eq('live_ca_differs' => false, 'signed_after_backup' => [], 'revoked_after_backup' => [], 'openvoxdb_nodes_unknown_to_archive' => nil)
      expect(data['settings_stripped']).to eq([])
      expect(data['services_stopped']).to eq([])
      expect(data['warnings']).to eq([])
      expect(cat('/etc/puppetlabs/puppetserver/conf.d/webserver.conf')).to eq("webserver: { good: true }\n")
      expect(cat('/etc/puppetlabs/puppet/autosign.conf')).to eq("autosign\n")
      expect(cat('/etc/puppetlabs/puppetserver/conf.d/added.conf')).to eq("added\n")
      expect(run_shell("stat -c '%a %u' #{cadir}/ca_key.pem")['stdout'].strip).to eq('640 65534')
      # Directories the archive holds only for their record files keep their modes.
      expect(run_shell("stat -c '%a' /etc/puppetlabs/code /etc/puppetlabs/code/environments /etc/puppetlabs/code/environments/production")['stdout'].split).to eq(%w[755 755 755])
      expect(run_shell("stat -c '%a' /root/.ssh/deploy_key")['stdout'].strip).to eq('600')
      expect(run_shell("ls -A #{destination}")['stdout'].split).to eq([File.basename(archive)])
    end

    it 'reports without touching anything with dry_run' do
      archive = backup
      run_shell("echo changed > /etc/puppetlabs/puppetserver/conf.d/webserver.conf; rm /etc/puppetlabs/puppet/autosign.conf")
      data = restore('archive' => archive, 'dry_run' => true).result
      expect(data['status']).to eq('dry_run')
      expect(data['changed']).to eq(['/etc/puppetlabs/puppetserver/conf.d/webserver.conf'])
      expect(data['missing']).to eq(['/etc/puppetlabs/puppet/autosign.conf'])
      expect(cat('/etc/puppetlabs/puppetserver/conf.d/webserver.conf')).to eq("changed\n")
      expect(run_shell('test -e /etc/puppetlabs/puppet/autosign.conf && echo yes || echo no')['stdout'].strip).to eq('no')
    end

    it 'restores only the items in scope' do
      archive = backup
      run_shell("echo changed > /etc/puppetlabs/puppetserver/conf.d/webserver.conf; echo NEWKEY > #{cadir}/ca_key.pem")
      data = restore('archive' => archive, 'scope' => 'ca').result
      expect(data['status']).to eq('restored')
      expect(data['scope']).to eq(['ca'])
      expect(data['changed']).to eq(["#{cadir}/ca_key.pem"])
      expect(cat("#{cadir}/ca_key.pem")).to eq("CAKEY\n")
      expect(cat('/etc/puppetlabs/puppetserver/conf.d/webserver.conf')).to eq("changed\n")

      data = restore('archive' => archive, 'scope' => 'config').result
      expect(data['changed']).to eq(['/etc/puppetlabs/puppetserver/conf.d/webserver.conf'])
      expect(cat('/etc/puppetlabs/puppetserver/conf.d/webserver.conf')).to eq("webserver: { good: true }\n")

      # code brings r10k's configuration with it
      run_shell('rm /etc/puppetlabs/r10k/r10k.yaml')
      data = restore('archive' => archive, 'scope' => 'code').result
      expect(data['missing']).to eq(['/etc/puppetlabs/r10k/r10k.yaml'])
      expect(cat('/etc/puppetlabs/r10k/r10k.yaml')).to eq(":cachedir: /var/cache/r10k\n")
    end

    it 'stops a service that is still starting, restores, and starts it again' do
      archive = backup
      run_shell(<<~SH)
        cat > /usr/local/sbin/systemctl <<'FAKE'
        #!/bin/bash
        echo "$*" >> /tmp/systemctl.log
        case "$1 $2" in "is-active puppetserver") echo activating; exit 3 ;; "is-active puppetdb") echo inactive; exit 3 ;; esac
        exit 0
        FAKE
        chmod 0755 /usr/local/sbin/systemctl; rm -f /tmp/systemctl.log
      SH
      data = restore('archive' => archive, 'scope' => 'ca').result
      run_shell('rm -f /usr/local/sbin/systemctl')
      expect(data['status']).to eq('restored')
      expect(data['services_stopped']).to eq(['puppetserver'])
      expect(run_shell('cat /tmp/systemctl.log')['stdout'].lines.map(&:strip)).to eq(
        ['is-active puppetserver', 'stop puppetserver', 'is-active puppetdb', 'start puppetserver']
      )
    end

    it 'leaves excluded paths out of a pass' do
      archive = backup
      run_shell("echo changed > /etc/puppetlabs/puppetserver/conf.d/webserver.conf; echo changed > /etc/puppetlabs/puppet/puppet.conf; rm /etc/puppetlabs/puppet/autosign.conf")
      data = restore('archive' => archive, 'scope' => 'config', 'exclude' => '/etc/puppetlabs/puppet/puppet.conf,/etc/puppetlabs/puppet/routes.yaml').result
      expect(data['status']).to eq('restored')
      expect(data['excluded']).to eq(%w[/etc/puppetlabs/puppet/puppet.conf /etc/puppetlabs/puppet/routes.yaml])
      expect(data['changed']).to eq(['/etc/puppetlabs/puppetserver/conf.d/webserver.conf'])
      expect(data['missing']).to eq(['/etc/puppetlabs/puppet/autosign.conf'])
      expect(cat('/etc/puppetlabs/puppet/puppet.conf')).to eq("changed\n")
      expect(cat('/etc/puppetlabs/puppetserver/conf.d/webserver.conf')).to eq("webserver: { good: true }\n")
      result = restore('archive' => archive, 'scope' => 'config', 'exclude' => 'etc/puppetlabs/puppet/puppet.conf')
      expect(result.result['_error']['msg']).to eq("exclude path 'etc/puppetlabs/puppet/puppet.conf' is not absolute")
    end

    it 'refuses a scope item the archive does not hold' do
      archive = backup('ca' => false)
      result = restore('archive' => archive, 'scope' => 'ca')
      expect(result.exit_code).to eq(1)
      expect(result.result['_error']['msg']).to eq('the archive holds no ca')
      result = restore('archive' => archive, 'scope' => 'extra')
      expect(result.result['_error']['msg']).to eq('the archive holds no extra paths')
    end
  end

  context 'with the CA' do
    it 'refuses to replace a CA that signed certificates since the backup, unless forced' do
      archive = backup
      run_shell(<<~SH)
        printf '0x0003 2026-10-20T00:00:00UTC 2031-10-20T00:00:00UTC /CN=agent02.example.com\\n' >> #{cadir}/inventory.txt
        printf '0x0004\\n' > #{cadir}/serial
        echo NEW > #{cadir}/signed/agent02.example.com.pem
      SH
      result = restore('archive' => archive, 'scope' => 'ca')
      expect(result.exit_code).to eq(1)
      expect(result.result['_error']['msg']).to include('signed 1 certificate(s) since the backup: agent02.example.com (serial 0x0003)', 'force=true')
      expect(cat("#{cadir}/serial")).to eq("0x0004\n")

      data = restore('archive' => archive, 'scope' => 'ca', 'force' => true).result
      expect(data['status']).to eq('restored')
      expect(data['ca']['signed_after_backup']).to eq(['agent02.example.com (serial 0x0003)'])
      expect(data['warnings']).to eq(['the restored CA does not know 1 certificate(s) signed since the backup: agent02.example.com (serial 0x0003). ' \
                                      'Delete signed/<name>.pem for each and enrol the host again; do not use puppetserver ca clean on them, which would revoke a serial the restored CA reissues'])
      expect(cat("#{cadir}/serial")).to eq("0x0003\n")
      # The certificate signed after the backup stays on disk; the CA just does not know it.
      expect(cat("#{cadir}/signed/agent02.example.com.pem")).to eq("NEW\n")
    end

    it 'refuses to replace a CA that revoked certificates since the backup, unless forced' do
      skip 'openssl is not in this image' unless run_shell('command -v openssl && echo yes')['stdout'].include?('yes')
      # Real CRLs: the archive's with nothing revoked, the live one with serial 2 (agent01) revoked.
      run_shell(<<~SH)
        set -e
        cd /tmp && rm -rf crl && mkdir crl && cd crl
        openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.crt -subj /CN=lab-ca -days 2 >/dev/null 2>&1
        printf '01\n' > serial; : > index.txt; echo unique_subject=no > index.txt.attr
        cat > ca.cnf <<'CNF'
        [ca]
        default_ca = lab
        [lab]
        database = index.txt
        serial = serial
        certificate = ca.crt
        private_key = ca.key
        default_md = sha256
        default_crl_days = 2
        CNF
        openssl ca -config ca.cnf -gencrl -out empty.crl >/dev/null 2>&1
        openssl req -newkey rsa:2048 -nodes -keyout a.key -out a.csr -subj /CN=agent01.example.com >/dev/null 2>&1
        openssl x509 -req -in a.csr -CA ca.crt -CAkey ca.key -set_serial 2 -out a.crt -days 2 >/dev/null 2>&1
        openssl ca -config ca.cnf -revoke a.crt >/dev/null 2>&1
        openssl ca -config ca.cnf -gencrl -out revoked.crl >/dev/null 2>&1
        cp empty.crl #{cadir}/ca_crl.pem
      SH
      archive = backup
      run_shell("cp /tmp/crl/revoked.crl #{cadir}/ca_crl.pem")
      result = restore('archive' => archive, 'scope' => 'ca')
      expect(result.exit_code).to eq(1)
      expect(result.result['_error']['msg']).to eq('the CA has revoked 1 certificate(s) since the backup: agent01.example.com (serial 0x2). The restored CA would consider them valid again. ' \
                                                   'Pass force=true to restore anyway, then revoke them again with puppetserver ca revoke --certname <name>')
      data = restore('archive' => archive, 'scope' => 'ca', 'force' => true).result
      expect(data['status']).to eq('restored')
      expect(data['ca']['revoked_after_backup']).to eq(['agent01.example.com (serial 0x2)'])
      expect(data['warnings']).to eq(['the restored CA considers 1 certificate(s) revoked since the backup valid again: agent01.example.com (serial 0x2). Revoke them again with puppetserver ca revoke --certname <name>'])
      expect(cat("#{cadir}/ca_crl.pem")).to eq(cat('/tmp/crl/empty.crl'))
    ensure
      run_shell('rm -rf /tmp/crl')
    end

    it 'replaces a CA that is not the archived one, with a warning' do
      archive = backup
      run_shell("echo OTHERCA > #{cadir}/ca_crt.pem; printf '0x0001 x y /CN=other\\n' > #{cadir}/inventory.txt")
      data = restore('archive' => archive, 'scope' => 'ca').result
      expect(data['status']).to eq('restored')
      expect(data['ca']['live_ca_differs']).to be(true)
      expect(data['warnings']).to eq(['the CA on this host is not the one in the archive; it is replaced by the restore'])
      expect(cat("#{cadir}/ca_crt.pem")).to eq("CACRT\n")
    end

    it 'puts the CA in place when the host has none' do
      archive = backup
      run_shell("rm -rf #{cadir}")
      data = restore('archive' => archive, 'scope' => 'ca').result
      expect(data['status']).to eq('restored')
      expect(data['missing']).to include("#{cadir}/ca_key.pem", "#{cadir}/serial", "#{cadir}/signed/agent01.example.com.pem")
      # No OpenVoxDB in the container, so the fallback for the lost inventory says so.
      expect(data['warnings']).to eq(["no CA on this host; the archive's is put in place. OpenVoxDB did not answer on localhost:8080, " \
                                      "so the hosts enrolled since the backup could not be listed; compare its node list with the archive's inventory.txt"])
      expect(data['ca']['openvoxdb_nodes_unknown_to_archive']).to be_nil
      expect(run_shell("stat -c '%a %u' #{cadir}")['stdout'].strip).to eq('750 65534')
      expect(cat("#{cadir}/inventory.txt").lines.size).to eq(2)
    end
  end

  context 'on a rebuilt host' do
    it 'takes the OpenVoxDB settings out of the restored puppet.conf when asked, and leaves the rest' do
      run_shell(<<~SH)
        printf '[main]\ncertname = host\nserver = host\n\n[server]\nstoreconfigs = true\nstoreconfigs_backend = puppetdb\nreports = puppetdb\n\n[agent]\nenvironment = openvox9\n' > /etc/puppetlabs/puppet/puppet.conf
      SH
      archive = backup
      run_shell("printf '[main]\ncertname = host\n' > /etc/puppetlabs/puppet/puppet.conf")
      data = restore('archive' => archive, 'scope' => 'config', 'strip_openvoxdb_settings' => true).result
      expect(data['status']).to eq('restored')
      expect(data['settings_stripped']).to eq(%w[storeconfigs storeconfigs_backend reports])
      expect(cat('/etc/puppetlabs/puppet/puppet.conf')).to eq("[main]\ncertname = host\nserver = host\n\n[server]\n\n[agent]\nenvironment = openvox9\n")
      # The next pass puts the file back whole.
      data = restore('archive' => archive, 'scope' => 'config').result
      expect(data['settings_stripped']).to eq([])
      expect(cat('/etc/puppetlabs/puppet/puppet.conf')).to include("storeconfigs_backend = puppetdb\n")
    end
  end

  context 'with static catalog scripts' do
    it 'puts back the commands conf.d names, with the configuration' do
      run_shell(<<~SH)
        install -d /opt/puppetlabs/server/data/puppetserver/scripts
        printf '#!/bin/sh\necho abc\n' > /opt/puppetlabs/server/data/puppetserver/scripts/code_id.sh; chmod 0755 /opt/puppetlabs/server/data/puppetserver/scripts/code_id.sh
        printf 'versioned-code: {\n  code-id-command: "/opt/puppetlabs/server/data/puppetserver/scripts/code_id.sh"\n  code-content-command: "/opt/puppetlabs/server/data/puppetserver/scripts/code_content.sh"\n}\n' > /etc/puppetlabs/puppetserver/conf.d/versioned-code.conf
      SH
      result = run_bolt_task('ovadm::backup_create')
      expect(result.result['warnings']).to eq(['conf.d names /opt/puppetlabs/server/data/puppetserver/scripts/code_content.sh as a static catalog command, which does not exist on this host'])
      archive = result.result['archive']
      run_shell('rm -rf /opt/puppetlabs')
      data = restore('archive' => archive, 'scope' => 'config').result
      expect(data['status']).to eq('restored')
      expect(data['missing']).to include('/opt/puppetlabs/server/data/puppetserver/scripts/code_id.sh')
      expect(run_shell("stat -c '%a' /opt/puppetlabs/server/data/puppetserver/scripts/code_id.sh")['stdout'].strip).to eq('755')
      expect(cat('/opt/puppetlabs/server/data/puppetserver/scripts/code_id.sh')).to eq("#!/bin/sh\necho abc\n")
    ensure
      run_shell('rm -rf /opt/puppetlabs /etc/puppetlabs/puppetserver/conf.d/versioned-code.conf')
    end
  end

  context 'with an extra path whose directories the host does not have yet' do
    it 'makes those directories 0755, as the host would, and keeps the path its own mode' do
      run_shell('install -d -m 0755 /opt/extra; install -d -m 0700 /opt/extra/state; echo LOG > /opt/extra/state/log.jsonl; chmod 0600 /opt/extra/state/log.jsonl')
      archive = backup('extra_paths' => '/opt/extra/state/log.jsonl')
      run_shell('rm -rf /opt/extra')
      data = restore('archive' => archive, 'scope' => 'extra').result
      expect(data['status']).to eq('restored')
      expect(cat('/opt/extra/state/log.jsonl')).to eq("LOG\n")
      expect(run_shell("stat -c '%a' /opt/extra /opt/extra/state /opt/extra/state/log.jsonl")['stdout'].split).to eq(%w[755 755 600])
    ensure
      run_shell('rm -rf /opt/extra')
    end
  end

  context 'with files of a user the host does not have' do
    it 'puts them back by number and says so' do
      run_shell('chown 4242:4242 /etc/puppetlabs/puppetdb/conf.d/database.ini')
      archive = backup
      run_shell('chown 0:0 /etc/puppetlabs/puppetdb/conf.d/database.ini')
      data = restore('archive' => archive, 'scope' => 'config').result
      expect(data['status']).to eq('restored')
      expect(data['warnings']).to eq(['1 file(s) belong to uid:gid 4242:4242, which no user on this host has (for example /etc/puppetlabs/puppetdb/conf.d/database.ini); they are put back under those numbers. Install the package that creates the user, then chown them, or let the site\'s code do it'])
      expect(run_shell("stat -c '%u:%g' /etc/puppetlabs/puppetdb/conf.d/database.ini")['stdout'].strip).to eq('4242:4242')
    end
  end

  context 'against the wrong host or archive' do
    def repack(archive, shell)
      name = File.basename(archive, '.tar.gz')
      run_shell(<<~SH)
        set -e
        rm -rf /tmp/repack && mkdir /tmp/repack && tar -xzf #{archive} -C /tmp/repack && cd /tmp/repack/#{name}
        #{shell}
        find files ovadm -type f ! -path ovadm/SHA256SUMS -print0 | LC_ALL=C sort -z | xargs -0 sha256sum > ovadm/SHA256SUMS
        cd /tmp/repack && tar -czf #{archive} #{name}
      SH
    end

    it 'refuses an archive from another certname unless forced' do
      archive = backup
      repack(archive, %q(sed -i 's/^  "certname": ".*",$/  "certname": "other.example.com",/' ovadm/manifest.json))
      result = restore('archive' => archive)
      expect(result.exit_code).to eq(1)
      expect(result.result['_error']['msg']).to match(/\Athe archive is from other\.example\.com, this host is .*; pass force=true/)
      data = restore('archive' => archive, 'force' => true).result
      expect(data['status']).to eq('restored')
      expect(data['warnings'].first).to start_with('restoring an archive from other.example.com onto ')
    end

    it 'says how to install the server when the archive has one and the host does not' do
      archive = backup
      repack(archive, %q(sed -i 's/^    "openvox-server": null,$/    "openvox-server": "8.17.0-1.el10",/; s/^    "openvox-agent": null,$/    "openvox-agent": "8.30.0-1.el10",/' ovadm/manifest.json))
      result = restore('archive' => archive)
      expect(result.exit_code).to eq(1)
      expect(result.result['_error']['msg']).to eq('openvox-server is not installed; install it first, then restore: bolt plan run ovadm::install server_host=<this host> ovox_server_version=8.17.0 ovox_version=8.30.0')
    end

    it 'refuses an archive whose checksums do not match, whatever force says' do
      archive = backup
      name = File.basename(archive, '.tar.gz')
      run_shell("cd /tmp && rm -rf t && mkdir t && tar -xzf #{archive} -C t && echo X > t/#{name}/files/etc/puppetlabs/puppet/puppet.conf && tar -C t -czf #{archive} #{name}")
      result = restore('archive' => archive, 'force' => true)
      expect(result.exit_code).to eq(1)
      expect(result.result['_error']['msg']).to include('does not match its checksums: files/etc/puppetlabs/puppet/puppet.conf')
      expect(cat('/etc/puppetlabs/puppet/puppet.conf')).to eq("[main]\ncertname = host\n")
    end

    it 'leaves nothing behind' do
      archive = backup
      restore('archive' => archive)
      restore('archive' => archive, 'scope' => 'extra')
      expect(run_shell("ls -A #{destination}")['stdout'].split).to eq([File.basename(archive)])
    end
  end
end
