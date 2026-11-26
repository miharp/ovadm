# frozen_string_literal: true

require_relative 'spec_helper'
require 'json'

describe 'ovadm::status' do
  let(:server) { 'ovox.example.com' }

  let(:precheck_result) do
    {
      'status' => 'pass',
      'checks' => [{ 'check' => 'java', 'status' => 'pass', 'detail' => 'Java 17 found' }]
    }
  end

  let(:service_result) do
    { 'services' => [{ 'service' => 'puppetserver', 'status' => 'running' }] }
  end

  let(:version_result) { { 'version' => '8.3.1' } }

  let(:topology_result) do
    {
      'certname' => server,
      'ca' => true,
      'server_role' => 'openvox_server',
      'compilers' => ['compiler01.example.com'],
      'openvoxdb' => {
        'server_urls' => ['https://ovox.example.com:8081/'],
        'version' => '8.17.0-1.el10',
        'database' => { 'host' => 'localhost', 'port' => 5432, 'name' => 'puppetdb', 'user' => 'puppetdb', 'local' => true }
      },
      'postgresql' => { 'version' => '16.15', 'pg_dump' => true }
    }
  end

  let(:bare_topology) do
    {
      'certname' => server, 'ca' => false, 'server_role' => nil, 'compilers' => [],
      'openvoxdb' => { 'server_urls' => [], 'version' => nil, 'database' => nil },
      'postgresql' => { 'version' => nil, 'pg_dump' => false }
    }
  end

  def ca_cert(subject, role, days_left)
    { 'subject' => subject, 'role' => role, 'not_after' => '2041-11-07T17:17:41Z', 'days_left' => days_left, 'expired' => days_left.negative? }
  end

  # What ca_expiry reports on a CA host: a root and its intermediate, the
  # server's own certificate, and the copy of the CA the server trusts.
  def expiry_result(ca_days: 5474, own_days: 5474, crls: [], matches_ca: true, openvoxdb_ca: nil)
    certificates = [ca_cert('CN=Puppet CA: ovox', 'intermediate', ca_days), ca_cert('CN=Puppet Root CA: 0a1b', 'root', ca_days)]
    {
      'status' => 'ok', 'certname' => server,
      'ca' => { 'path' => '/etc/puppetlabs/puppetserver/ca/ca_crt.pem', 'layout' => 'intermediate', 'extendable' => true,
                'problems' => [], 'certificates' => certificates, 'crls' => crls },
      'local_ca' => { 'path' => '/etc/puppetlabs/puppet/ssl/certs/ca.pem', 'certificates' => certificates, 'matches_ca' => matches_ca },
      'host_cert' => { 'path' => "/etc/puppetlabs/puppet/ssl/certs/#{server}.pem", 'not_after' => '2041-11-07T17:17:44Z',
                       'days_left' => own_days, 'expired' => own_days.negative? },
      'host_crl' => nil, 'openvoxdb_ca' => openvoxdb_ca
    }
  end

  let(:no_expiry) do
    { 'status' => 'not_installed', 'certname' => nil, 'ca' => nil, 'local_ca' => nil, 'host_cert' => nil, 'host_crl' => nil, 'openvoxdb_ca' => nil }
  end

  def allow_all_tasks(topology = topology_result, expiry: expiry_result)
    allow_task('ovadm::precheck').always_return(precheck_result)
    allow_task('ovadm::service_status').always_return(service_result)
    allow_task('ovadm::get_version').always_return(version_result)
    allow_task('ovadm::topology').always_return(topology)
    allow_task('ovadm::ca_expiry').always_return(expiry)
  end

  it 'runs precheck, service_status, get_version, topology and ca_expiry' do
    expect_task('ovadm::precheck').be_called_times(1).always_return(precheck_result)
    expect_task('ovadm::service_status').be_called_times(1).always_return(service_result)
    expect_task('ovadm::get_version').be_called_times(1).always_return(version_result)
    expect_task('ovadm::topology').be_called_times(1).always_return(topology_result)
    expect_task('ovadm::ca_expiry').be_called_times(1).always_return(expiry_result)

    result = run_plan('ovadm::status', { 'server_host' => server })
    expect(result).to be_ok
  end

  it 'returns a hash with precheck, services, versions, topology and ca_expiry keys' do
    allow_all_tasks

    result = run_plan('ovadm::status', { 'server_host' => server })
    expect(result).to be_ok
    expect(result.value.keys).to contain_exactly('ovadm_version', 'precheck', 'services', 'versions', 'topology', 'ca_expiry')
  end

  it 'returns the topology the task reported' do
    allow_all_tasks

    result = run_plan('ovadm::status', { 'server_host' => server })
    topology = result.value['topology'].first.value
    expect(topology['compilers']).to eq(['compiler01.example.com'])
    expect(topology['openvoxdb']['database']['local']).to be(true)
  end

  it 'reports the compilers and where OpenVoxDB is' do
    allow_all_tasks
    expect_out_message.with_params("  Topology: server #{server} (CA), 1 compiler: compiler01.example.com")
    expect_out_message.with_params('  OpenVoxDB: the server reports to https://ovox.example.com:8081/')
    expect_out_message.with_params('  OpenVoxDB 8.17.0-1.el10 on this host, database puppetdb on this host (port 5432)')
    expect_out_message.with_params('  PostgreSQL 16.15 on this host')

    expect(run_plan('ovadm::status', { 'server_host' => server })).to be_ok
  end

  it 'copes with a host that has no CA, compilers, OpenVoxDB or PostgreSQL' do
    allow_all_tasks(bare_topology, expiry: no_expiry)
    expect_out_message.with_params("  Topology: server #{server} (no CA directory), no compilers")
    expect_out_message.with_params('  OpenVoxDB: the server sends nothing to OpenVoxDB (no puppetdb.conf)')

    expect(run_plan('ovadm::status', { 'server_host' => server })).to be_ok
  end

  context 'certificate expiry' do
    it 'reports when the CA certificates and the server certificate expire' do
      allow_all_tasks
      expect_out_message.with_params('  ✓ CA certificate CN=Puppet CA: ovox (intermediate): expires on 2041-11-07T17:17:41Z, in 5474 days')
      expect_out_message.with_params('  ✓ CA certificate CN=Puppet Root CA: 0a1b (root): expires on 2041-11-07T17:17:41Z, in 5474 days')
      expect_out_message.with_params("  ✓ certificate of #{server}: expires on 2041-11-07T17:17:44Z, in 5474 days")

      result = run_plan('ovadm::status', { 'server_host' => server })
      expect(result).to be_ok
      expect(result.value['ca_expiry'].first.value['ca']['layout']).to eq('intermediate')
    end

    it 'warns when a CA certificate has less than a year left, and names the plan that extends it' do
      allow_all_tasks(expiry: expiry_result(ca_days: 364))
      expect_out_message.with_params('  ! CA certificate CN=Puppet CA: ovox (intermediate): expires on 2041-11-07T17:17:41Z, in 364 days; extend it with ovadm::extend_ca')

      expect(run_plan('ovadm::status', { 'server_host' => server })).to be_ok
    end

    it 'says so when the CA and the server certificate have expired' do
      allow_all_tasks(expiry: expiry_result(ca_days: -2, own_days: -2))
      expect_out_message.with_params('  ✗ CA certificate CN=Puppet Root CA: 0a1b (root): expired on 2041-11-07T17:17:41Z; extend it with ovadm::extend_ca')
      expect_out_message.with_params("  ✗ certificate of #{server}: expired on 2041-11-07T17:17:44Z")

      expect(run_plan('ovadm::status', { 'server_host' => server })).to be_ok
    end

    it 'warns about a server certificate and a CRL within 30 days of expiry' do
      crl = { 'path' => '/etc/puppetlabs/puppetserver/ca/ca_crl.pem', 'issuer' => 'CN=Puppet Root CA: 0a1b',
              'next_update' => '2026-12-01T00:00:00Z', 'days_left' => 19, 'expired' => false }
      allow_all_tasks(expiry: expiry_result(own_days: 29, crls: [crl]))
      expect_out_message.with_params("  ! certificate of #{server}: expires on 2041-11-07T17:17:44Z, in 29 days")
      expect_out_message.with_params('  ! CRL of CN=Puppet Root CA: 0a1b in /etc/puppetlabs/puppetserver/ca/ca_crl.pem: expires on 2026-12-01T00:00:00Z, in 19 days; ovadm::extend_ca re-signs it')

      expect(run_plan('ovadm::status', { 'server_host' => server })).to be_ok
    end

    it "says when the server's or OpenVoxDB's copy of the CA is not the CA directory's" do
      pdb = { 'path' => '/etc/puppetlabs/puppetdb/ssl/ca.pem', 'certificates' => [], 'matches_local' => false }
      allow_all_tasks(expiry: expiry_result(matches_ca: false, openvoxdb_ca: pdb))
      expect_out_message.with_params('  ! /etc/puppetlabs/puppet/ssl/certs/ca.pem, the copy of the CA this server trusts, differs from the CA directory; ovadm::extend_ca with distribute_only=true replaces it')
      expect_out_message.with_params("  ! /etc/puppetlabs/puppetdb/ssl/ca.pem, OpenVoxDB's copy of the CA, differs from the host's; ovadm::extend_ca with distribute_only=true replaces it")

      expect(run_plan('ovadm::status', { 'server_host' => server })).to be_ok
    end

    it "reports a compiler's copy of the CA" do
      copy = expiry_result.merge('ca' => nil)
      copy['local_ca'] = copy['local_ca'].merge('matches_ca' => nil)
      allow_all_tasks(bare_topology, expiry: copy)
      expect_out_message.with_params('  ✓ copy of CA certificate CN=Puppet CA: ovox: expires on 2041-11-07T17:17:41Z, in 5474 days')

      expect(run_plan('ovadm::status', { 'server_host' => server })).to be_ok
    end
  end

  it 'marks a compiler whose certificate is revoked' do
    allow_all_tasks(topology_result.merge('compilers' => ['compiler01.example.com', 'compiler02.example.com'], 'compilers_revoked' => ['compiler02.example.com']))
    expect_out_message.with_params("  Topology: server #{server} (CA), 2 compilers: compiler01.example.com, compiler02.example.com (revoked)")

    expect(run_plan('ovadm::status', { 'server_host' => server })).to be_ok
  end

  context "a host's own copy of the CRL" do
    let(:compiler) { 'compiler01.example.com' }
    let(:signer)   { 'CN=Puppet CA: ovox' }

    def crl(number: 4, revoked: 3, days_left: 1824, path: nil)
      described = { 'issuer' => signer, 'next_update' => '2031-11-24T13:13:03Z', 'days_left' => days_left,
                    'expired' => days_left.negative?, 'crl_number' => number, 'revoked' => revoked }
      path ? described.merge('path' => path) : described
    end

    # What ca_expiry says on a compiler: no CA directory, a copy of the CRLs.
    def compiler_report(crls, revoked: false)
      report = expiry_result.merge('certname' => compiler, 'ca' => nil)
      report['local_ca'] = report['local_ca'].merge('matches_ca' => nil)
      report['host_cert'] = report['host_cert'].merge('revoked' => revoked)
      report.merge('host_crl' => { 'path' => '/etc/puppetlabs/puppet/ssl/crl.pem', 'crls' => crls })
    end

    # The CA at CRL number 4, and an infrastructure CRL that never counts.
    def allow_server_and_compiler(compiler_expiry)
      allow_all_tasks
      ca = expiry_result(crls: [crl(path: '/etc/puppetlabs/puppetserver/ca/ca_crl.pem'),
                                crl(number: 0, revoked: 0, path: '/etc/puppetlabs/puppetserver/ca/infra_crl.pem')])
      allow_task('ovadm::ca_expiry').return_for_targets(server => ca, compiler => compiler_expiry)
    end

    it "warns when it is behind the CA's, and names the plan that replaces it" do
      allow_server_and_compiler(compiler_report([crl(number: 2, revoked: 1)]))
      expect_out_message.with_params(
        "  ! copy of the CRL of #{signer}: behind the CA's (number 2, the CA has 4), " \
        'so this host does not refuse the certificates revoked since; ovadm::sync_crl replaces it',
      )

      expect(run_plan('ovadm::status', { 'server_host' => [server, compiler] })).to be_ok
    end

    it "says so when it is the same as the CA's" do
      allow_server_and_compiler(compiler_report([crl]))
      expect_out_message.with_params("  ✓ copy of the CRL of #{signer}: the same as the CA's (number 4, 3 revoked)")

      expect(run_plan('ovadm::status', { 'server_host' => [server, compiler] })).to be_ok
    end

    it 'says that a copy that has run out refuses everything' do
      allow_server_and_compiler(compiler_report([crl(days_left: -1)]))
      expect_out_message.with_params(
        "  ✗ copy of the CRL of #{signer}: ran out on 2031-11-24T13:13:03Z, " \
        'so every certificate checked against it is refused; ovadm::sync_crl replaces it',
      )

      expect(run_plan('ovadm::status', { 'server_host' => [server, compiler] })).to be_ok
    end

    it 'warns about a copy within 30 days of its end when the CA is not among the hosts' do
      allow_all_tasks(bare_topology, expiry: compiler_report([crl(days_left: 12)]))
      expect_out_message.with_params("  ! copy of the CRL of #{signer}: runs out on 2031-11-24T13:13:03Z, in 12 days; ovadm::sync_crl replaces it")

      expect(run_plan('ovadm::status', { 'server_host' => compiler })).to be_ok
    end

    it "says when the host's own certificate is on it, in place of the expiry" do
      allow_server_and_compiler(compiler_report([crl], revoked: true))
      expect_out_message.with_params("  ✗ certificate of #{compiler}: revoked. Nothing that has the current CRL accepts it.")
      expect_out_message.with_params("  ✓ certificate of #{compiler}: expires on 2041-11-07T17:17:44Z, in 5474 days").not_be_called

      expect(run_plan('ovadm::status', { 'server_host' => [server, compiler] })).to be_ok
    end
  end

  it "reports ovadm's own version from metadata.json" do
    allow_all_tasks

    expected = JSON.parse(File.read(File.expand_path('../../metadata.json', __dir__)))['version']

    result = run_plan('ovadm::status', { 'server_host' => server })
    expect(result).to be_ok
    expect(result.value['ovadm_version']).to eq(expected)
    expect(result.value['ovadm_version']).to match(/\A\d+\.\d+\.\d+\z/)
  end
end
