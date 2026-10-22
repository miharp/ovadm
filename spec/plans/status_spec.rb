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

  def allow_all_tasks(topology = topology_result)
    allow_task('ovadm::precheck').always_return(precheck_result)
    allow_task('ovadm::service_status').always_return(service_result)
    allow_task('ovadm::get_version').always_return(version_result)
    allow_task('ovadm::topology').always_return(topology)
  end

  it 'runs precheck, service_status, get_version and topology' do
    expect_task('ovadm::precheck').be_called_times(1).always_return(precheck_result)
    expect_task('ovadm::service_status').be_called_times(1).always_return(service_result)
    expect_task('ovadm::get_version').be_called_times(1).always_return(version_result)
    expect_task('ovadm::topology').be_called_times(1).always_return(topology_result)

    result = run_plan('ovadm::status', { 'server_host' => server })
    expect(result).to be_ok
  end

  it 'returns a hash with precheck, services, versions and topology keys' do
    allow_all_tasks

    result = run_plan('ovadm::status', { 'server_host' => server })
    expect(result).to be_ok
    expect(result.value.keys).to contain_exactly('ovadm_version', 'precheck', 'services', 'versions', 'topology')
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
    allow_all_tasks(bare_topology)
    expect_out_message.with_params("  Topology: server #{server} (no CA directory), no compilers")
    expect_out_message.with_params('  OpenVoxDB: the server sends nothing to OpenVoxDB (no puppetdb.conf)')

    expect(run_plan('ovadm::status', { 'server_host' => server })).to be_ok
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
