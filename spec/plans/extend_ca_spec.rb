# frozen_string_literal: true

require_relative 'spec_helper'

describe 'ovadm::extend_ca' do
  let(:server)   { 'ovox-server.example.com' }
  let(:compiler) { 'ovox-compiler01.example.com' }
  let(:agent)    { 'agent01.example.com' }

  let(:lock)     { 'ovadm extend_ca in progress' }
  let(:disabled) { { 'status' => 'disabled', 'disabled_here' => true, 'message' => lock, 'waited' => 0 } }
  let(:enabled)  { { 'status' => 'enabled', 'message' => lock } }

  let(:archive) { "/var/backups/openvox/openvox-backup-#{server}-20261111T120000Z.tar.gz" }
  let(:backup_result) { { 'backup' => [], 'archives' => { server => archive }, 'verify' => {} } }

  let(:bundle) { "-----BEGIN CERTIFICATE-----\nNEW\n-----END CERTIFICATE-----\n" }
  let(:crl)    { "-----BEGIN X509 CRL-----\nNEW\n-----END X509 CRL-----\n" }
  let(:bundle_params) { { 'bundle' => bundle, 'crl' => crl } }

  def cert(subject, role, days_left)
    {
      'subject' => subject, 'issuer' => 'CN=Puppet Root CA: 0a1b', 'role' => role, 'serial' => '01',
      'not_after' => '2041-11-07T17:17:41Z', 'days_left' => days_left, 'expired' => days_left.negative?,
      'key' => '/etc/puppetlabs/puppetserver/ca/root_key.pem'
    }
  end

  def host_cert(days_left)
    { 'path' => '/etc/puppetlabs/puppet/ssl/certs/host.pem', 'not_after' => '2031-11-10T17:20:00Z',
      'days_left' => days_left, 'expired' => days_left.negative?, 'signed_by_local_ca' => true }
  end

  # What ca_expiry says on the CA host.
  def ca_report(days_left: 400, extendable: true, problems: [], own_days_left: 5000, include_bundle: false)
    ca = {
      'path' => '/etc/puppetlabs/puppetserver/ca/ca_crt.pem', 'layout' => 'intermediate',
      'extendable' => extendable, 'problems' => problems,
      'certificates' => [cert('CN=Puppet CA: ovox', 'intermediate', days_left), cert('CN=Puppet Root CA: 0a1b', 'root', days_left)],
      'crls' => [], 'not_after' => '2041-11-07T17:17:41Z', 'days_left' => days_left, 'expired' => days_left.negative?
    }
    ca = ca.merge('bundle' => bundle, 'crl' => crl) if include_bundle
    {
      'status' => 'ok', 'certname' => server, 'ca' => ca,
      'local_ca' => { 'path' => '/etc/puppetlabs/puppet/ssl/certs/ca.pem', 'not_after' => '2041-11-07T17:17:41Z', 'matches_ca' => true },
      'host_cert' => host_cert(own_days_left), 'host_crl' => nil, 'openvoxdb_ca' => nil
    }
  end

  def host_report(certname, own_days_left: 1800)
    {
      'status' => 'ok', 'certname' => certname, 'ca' => nil,
      'local_ca' => { 'path' => '/etc/puppetlabs/puppet/ssl/certs/ca.pem', 'not_after' => '2041-11-06T12:00:00Z', 'matches_ca' => nil },
      'host_cert' => host_cert(own_days_left), 'host_crl' => nil, 'openvoxdb_ca' => nil
    }
  end

  let(:extended) do
    {
      'status' => 'extended', 'path' => '/etc/puppetlabs/puppetserver/ca/ca_crt.pem', 'ttl' => '15y',
      'certificates' => [
        { 'subject' => 'CN=Puppet CA: ovox', 'role' => 'intermediate', 'old_not_after' => '2027-12-16T12:00:00Z',
          'new_not_after' => '2041-11-06T12:00:00Z', 'was_expired' => false }
      ],
      'crls' => [
        { 'path' => '/etc/puppetlabs/puppetserver/ca/ca_crl.pem', 'issuer' => 'CN=Puppet CA: ovox',
          'old_next_update' => '2027-12-16T12:00:00Z', 'new_next_update' => '2041-11-06T12:00:00Z', 'crl_number' => 4, 'revoked' => 2 }
      ],
      'warnings' => [], 'backups' => ['/etc/puppetlabs/puppetserver/ca/ca_crt.pem.20261111T120000Z.bak'],
      'bundle' => bundle, 'crl' => crl
    }
  end

  def installed(certname, changed: ['/etc/puppetlabs/puppet/ssl/certs/ca.pem'], openvoxdb: nil, status: nil)
    {
      'status' => status || (changed.empty? ? 'unchanged' : 'installed'), 'certname' => certname, 'changed' => changed,
      'localcacert' => { 'path' => '/etc/puppetlabs/puppet/ssl/certs/ca.pem', 'action' => changed.empty? ? 'unchanged' : 'updated' },
      'hostcrl' => nil, 'openvoxdb_ca' => openvoxdb, 'not_after' => '2041-11-06T12:00:00Z'
    }
  end

  let(:regenerated) do
    {
      'status' => 'regenerated', 'certname' => server, 'old_not_after' => '2026-11-01T00:00:00Z',
      'new_not_after' => '2041-11-06T12:00:00Z', 'subject_alt_names' => 'DNS:puppet', 'alt_names_dropped' => 0,
      'extensions_lost' => '', 'backup' => '/etc/puppetlabs/puppet/ssl.server-cert.20261111T120000Z.bak', 'openvoxdb' => nil
    }
  end

  # Every task the plan can run, answering as a healthy run would. Called
  # first in an example: BoltSpec tries the stub added last first, so what an
  # example stubs after this takes precedence.
  def allow_the_rest(report: ca_report)
    allow_task('ovadm::ca_expiry').return_for_targets(
      server => report, compiler => host_report(compiler), agent => host_report(agent)
    )
    allow_task('ovadm::agent_disable').always_return(disabled)
    allow_task('ovadm::agent_enable').always_return(enabled)
    allow_plan('ovadm::backup').always_return(backup_result)
    allow_task('ovadm::service_stop').always_return('status' => 'stopped')
    allow_task('ovadm::service_start').always_return('status' => 'started')
    allow_task('ovadm::service_restart').always_return('status' => 'restarted')
    allow_task('ovadm::wait_until_service_ready').always_return('status' => 'ready')
    allow_task('ovadm::ca_extend').always_return(extended)
    allow_task('ovadm::ca_bundle_install').return_for_targets(
      server => installed(server), compiler => installed(compiler), agent => installed(agent)
    )
    allow_task('ovadm::server_cert_regen').always_return(regenerated)
  end

  before(:each) { execute_no_plan }

  context 'on a server alone' do
    it 'backs up, stops the server, extends, installs the bundle and starts it again' do
      allow_the_rest
      expect_plan('ovadm::backup')
        .with_params('server_host' => server, 'destination' => '/var/backups/openvox')
        .be_called_times(1).always_return(backup_result)
      expect_task('ovadm::service_stop').with_targets([server]).be_called_times(1).always_return('status' => 'stopped')
      expect_task('ovadm::ca_extend').with_targets([server]).with_params('ttl' => '15y').be_called_times(1).always_return(extended)
      expect_task('ovadm::ca_bundle_install').with_targets([server]).with_params(bundle_params)
                                             .be_called_times(1).always_return(installed(server))
      expect_task('ovadm::service_start').with_targets([server]).be_called_times(1).always_return('status' => 'started')
      expect_task('ovadm::wait_until_service_ready').with_targets([server]).with_params('puppetdb' => false)
                                                    .be_called_times(1).always_return('status' => 'ready')
      expect_task('ovadm::server_cert_regen').not_be_called
      expect_task('ovadm::service_restart').not_be_called

      result = run_plan('ovadm::extend_ca', { 'server_host' => server })
      expect(result).to be_ok
      expect(result.value['backup']).to eq(archive)
      expect(result.value['ca']['status']).to eq('extended')
      expect(result.value['ca']).not_to include('bundle', 'crl')
      expect(result.value['server_cert']).to be_nil
      expect(result.value['installed']).to eq(server => ['/etc/puppetlabs/puppet/ssl/certs/ca.pem'])
      expect(result.value['failed']).to eq({})
      expect(result.value['expiry'][server]).to include('ca_not_after', 'host_cert_days_left' => 5000)
      expect(result.value['agents_held']).to eq([server])
    end

    it 'passes ttl through and takes no backup with skip_backup' do
      allow_the_rest
      expect_plan('ovadm::backup').not_be_called
      expect_task('ovadm::ca_extend').with_params('ttl' => '20y').be_called_times(1).always_return(extended)

      result = run_plan('ovadm::extend_ca', { 'server_host' => server, 'ttl' => '20y', 'skip_backup' => true })
      expect(result).to be_ok
      expect(result.value['backup']).to be_nil
    end

    it 'refuses a ttl that is not a duration' do
      result = run_plan('ovadm::extend_ca', { 'server_host' => server, 'ttl' => 'forever' })
      expect(result).not_to be_ok
    end

    it 'refuses more than one server' do
      result = run_plan('ovadm::extend_ca', { 'server_host' => [server, compiler] })
      expect(result).not_to be_ok
      expect(result.value.msg).to include('must name one host')
    end

    it 'stops before touching anything on a host that is not the CA' do
      allow_task('ovadm::ca_expiry').always_return(host_report(server))
      expect_task('ovadm::agent_disable').not_be_called
      expect_task('ovadm::service_stop').not_be_called
      expect_task('ovadm::ca_extend').not_be_called

      result = run_plan('ovadm::extend_ca', { 'server_host' => server })
      expect(result).not_to be_ok
      expect(result.value.msg).to include('has no CA directory')
    end

    it 'stops before touching anything when the CA cannot be extended, and says why' do
      problem = 'the private key of CN=Example Root is not on this host: an externally issued CA is extended by its owner'
      allow_the_rest(report: ca_report(extendable: false, problems: [problem]))
      expect_task('ovadm::service_stop').not_be_called
      expect_task('ovadm::ca_extend').not_be_called

      result = run_plan('ovadm::extend_ca', { 'server_host' => server })
      expect(result).not_to be_ok
      expect(result.value.msg).to eq("The CA on #{server} cannot be extended: #{problem}")
    end

    it 'starts the server again and enables the agent when the extension fails' do
      allow_the_rest
      expect_task('ovadm::ca_extend').error_with('msg' => 'The re-signed CN=Puppet CA: ovox does not verify. Nothing was changed.', 'kind' => 'ovadm/ca-extend')
      expect_task('ovadm::ca_bundle_install').not_be_called
      expect_task('ovadm::service_start').with_targets([server]).be_called_times(1).always_return('status' => 'started')
      expect_task('ovadm::agent_enable').with_targets([server]).be_called_times(1).always_return(enabled)

      result = run_plan('ovadm::extend_ca', { 'server_host' => server })
      expect(result).not_to be_ok
    end

    it 'changes nothing when the agent cannot be disabled' do
      allow_the_rest
      allow_task('ovadm::agent_disable').error_with('msg' => 'an agent run (pid 4242) has not finished after 300 s', 'kind' => 'ovadm/agent')
      expect_task('ovadm::service_stop').not_be_called
      expect_task('ovadm::ca_extend').not_be_called

      result = run_plan('ovadm::extend_ca', { 'server_host' => server })
      expect(result).not_to be_ok
      expect(result.value.msg).to include('Could not disable the agent, so nothing was changed.')
    end
  end

  context 'with a dry run' do
    it 'asks ca_extend what it would do and touches nothing' do
      allow_the_rest
      # Bolt turns _noop into both an option and a task parameter, which
      # with_params cannot describe, so the parameters are captured instead.
      seen = nil
      expect_task('ovadm::ca_extend').be_called_times(1).return do |targets:, task:, params:| # rubocop:disable Lint/UnusedBlockArgument
        seen = params
        Bolt::ResultSet.new(targets.map { |target| Bolt::Result.new(target, value: extended.merge('status' => 'noop')) })
      end
      expect_task('ovadm::agent_disable').not_be_called
      expect_plan('ovadm::backup').not_be_called
      expect_task('ovadm::service_stop').not_be_called
      expect_task('ovadm::ca_bundle_install').not_be_called

      result = run_plan('ovadm::extend_ca', { 'server_host' => server, 'compiler_hosts' => compiler, 'dry_run' => true })
      expect(result).to be_ok
      expect(seen).to include('ttl' => '15y', '_noop' => true)
      expect(result.value['ca']['status']).to eq('noop')
      expect(result.value['regenerate_server_cert']).to be(false)
    end
  end

  context "when the server's own certificate has expired" do
    it 'replaces it after the CA is extended' do
      allow_the_rest(report: ca_report(days_left: -3, own_days_left: -3))
      expect_task('ovadm::server_cert_regen').with_targets([server]).be_called_times(1).always_return(regenerated)

      result = run_plan('ovadm::extend_ca', { 'server_host' => server })
      expect(result).to be_ok
      expect(result.value['server_cert']['status']).to eq('regenerated')
    end

    it 'leaves it with regenerate_server_cert=false' do
      allow_the_rest(report: ca_report(days_left: -3, own_days_left: -3))
      expect_task('ovadm::server_cert_regen').not_be_called

      result = run_plan('ovadm::extend_ca', { 'server_host' => server, 'regenerate_server_cert' => false })
      expect(result).to be_ok
      expect(result.value['server_cert']).to be_nil
    end

    it 'restarts OpenVoxDB and waits for it when its copies were replaced' do
      allow_the_rest(report: ca_report(days_left: -3, own_days_left: -3))
      allow_task('ovadm::server_cert_regen').always_return(regenerated.merge('openvoxdb' => 'updated'))
      expect_command('systemctl try-restart puppetdb').with_targets([server]).be_called_times(1)
      expect_task('ovadm::wait_until_service_ready').with_targets([server]).with_params('puppetdb' => true)
                                                    .be_called_times(1).always_return('status' => 'ready')

      expect(run_plan('ovadm::extend_ca', { 'server_host' => server })).to be_ok
    end
  end

  it 'replaces a valid server certificate when asked to' do
    allow_the_rest
    expect_task('ovadm::server_cert_regen').be_called_times(1).always_return(regenerated)

    result = run_plan('ovadm::extend_ca', { 'server_host' => server, 'regenerate_server_cert' => true })
    expect(result).to be_ok
  end

  context 'with compilers and agent hosts' do
    let(:params) { { 'server_host' => server, 'compiler_hosts' => compiler, 'agent_hosts' => agent } }

    it 'gives each compiler the bundle and a restart, and each agent host the bundle' do
      allow_the_rest
      expect_task('ovadm::agent_disable').with_targets([server, compiler]).be_called_times(1).always_return(disabled)
      expect_task('ovadm::service_restart').with_targets([compiler]).with_params('_catch_errors' => true)
                                           .be_called_times(1).always_return('status' => 'restarted')

      result = run_plan('ovadm::extend_ca', params)
      expect(result).to be_ok
      expect(result.value['installed'].keys).to eq([server, compiler, agent])
      expect(result.value['failed']).to eq({})
      expect(result.value['expiry'].keys).to eq([server, compiler, agent])
      expect(result.value['agents_held']).to eq([server, compiler])
    end

    it 'restarts a compiler whose agent had already fetched the bundle' do
      allow_the_rest
      allow_task('ovadm::ca_bundle_install').return_for_targets(
        server => installed(server), compiler => installed(compiler, changed: []), agent => installed(agent, changed: [])
      )
      expect_task('ovadm::service_restart').with_targets([compiler]).with_params('_catch_errors' => true)
                                           .be_called_times(1).always_return('status' => 'restarted')

      result = run_plan('ovadm::extend_ca', params)
      expect(result).to be_ok
      expect(result.value['installed']).to include(compiler => [], agent => [])
    end

    it 'finishes the other hosts when one fails, then fails naming it' do
      allow_the_rest
      allow_task('ovadm::ca_bundle_install').return_for_targets(
        server => installed(server), compiler => installed(compiler),
        agent => installed(agent, changed: [], status: 'not_enrolled')
      )
      expect_task('ovadm::service_restart').with_targets([compiler]).with_params('_catch_errors' => true)
                                           .be_called_times(1).always_return('status' => 'restarted')
      expect_task('ovadm::agent_enable').with_targets([server, compiler]).be_called_times(1).always_return(enabled)

      result = run_plan('ovadm::extend_ca', params)
      expect(result).not_to be_ok
      expect(result.value.msg).to include("#{agent} did not get the new bundle", 'distribute_only=true')
      expect(result.value.details['failed']).to eq(agent => 'it has no certificate from this CA (not_enrolled)')
      expect(result.value.details['installed'].keys).to eq([server, compiler])
    end

    it 'names a host whose own certificate the extension does not help' do
      allow_the_rest
      allow_task('ovadm::ca_expiry').return_for_targets(
        server => ca_report, compiler => host_report(compiler), agent => host_report(agent, own_days_left: -40)
      )

      result = run_plan('ovadm::extend_ca', params)
      expect(result).to be_ok
      expect(result.value['expiry'][agent]['host_cert_days_left']).to eq(-40)
    end
  end

  context 'with distribute_only' do
    let(:params) { { 'server_host' => server, 'compiler_hosts' => compiler, 'agent_hosts' => agent, 'distribute_only' => true } }

    def allow_reports
      allow_task('ovadm::ca_expiry').return_for_targets(
        server => ca_report(include_bundle: true), compiler => host_report(compiler), agent => host_report(agent)
      )
    end

    it 'extends nothing, and gives every host the bundle the CA has' do
      allow_the_rest
      allow_reports
      expect_task('ovadm::ca_extend').not_be_called
      expect_task('ovadm::service_stop').not_be_called
      expect_plan('ovadm::backup').not_be_called
      allow_task('ovadm::ca_bundle_install').return_for_targets(
        server => installed(server, changed: []), compiler => installed(compiler), agent => installed(agent)
      )
      expect_task('ovadm::service_restart').with_targets([compiler]).with_params('_catch_errors' => true)
                                           .be_called_times(1).always_return('status' => 'restarted')

      result = run_plan('ovadm::extend_ca', params)
      expect(result).to be_ok
      expect(result.value['ca']).to be_nil
      expect(result.value['backup']).to be_nil
      expect(result.value['installed']).to include(server => [], compiler => ['/etc/puppetlabs/puppet/ssl/certs/ca.pem'])
    end

    it 'restarts the server when its own copy was the old one' do
      allow_the_rest
      allow_reports
      expect_task('ovadm::service_restart').be_called_times(2).always_return('status' => 'restarted')

      expect(run_plan('ovadm::extend_ca', params)).to be_ok
    end

    it 'refuses an expired CA' do
      allow_task('ovadm::ca_expiry').always_return(ca_report(days_left: -3, include_bundle: true))
      expect_task('ovadm::ca_bundle_install').not_be_called

      result = run_plan('ovadm::extend_ca', params)
      expect(result).not_to be_ok
      expect(result.value.msg).to include('has expired', 'without distribute_only')
    end

    it 'refuses regenerate_server_cert=true' do
      result = run_plan('ovadm::extend_ca', params.merge('regenerate_server_cert' => true))
      expect(result).not_to be_ok
      expect(result.value.msg).to include('needs the server stopped')
    end
  end
end
