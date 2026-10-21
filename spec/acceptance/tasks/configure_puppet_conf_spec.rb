# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'ovadm::configure_puppet_conf task' do
  let(:path) { '/etc/puppetlabs/puppet/puppet.conf' }

  # What Foreman's puppet.conf template leaves on a host, on EL and Debian
  # alike: the directories moved to /var/lib/puppet, ssldir following vardir.
  let(:foreman_conf) do
    <<~CONF
      [main]
      vardir = /var/lib/puppet
      logdir = /var/log/puppet
      rundir = /var/run/puppet
      ssldir = $vardir/ssl

      [agent]
      pluginsync      = true
      report          = true
      server          = old.example.com
    CONF
  end

  def seed(content)
    run_shell("mkdir -p #{File.dirname(path)}\ncat > #{path} <<'CONF'\n#{content}CONF\n")
  end

  # Every example starts on a host with no file.
  before { run_shell("rm -f #{path}") }

  it 'returns success and the config file path' do
    result = run_bolt_task('ovadm::configure_puppet_conf', { 'server' => 'test.example.com' })
    expect(result.exit_code).to eq(0)
    data = result.result
    expect(data['status']).to eq('success')
    expect(data['path']).to eq(path)
    expect(data['kept']).to eq([])
  end

  it 'keeps the directory settings of an existing [main] section and reports them' do
    seed(foreman_conf)
    result = run_bolt_task('ovadm::configure_puppet_conf', {
      'certname' => 'node.example.com',
      'server'   => 'puppet.example.com',
    })
    expect(result.exit_code).to eq(0)
    expect(result.result['kept']).to eq(%w[vardir logdir rundir ssldir])
    conf = run_shell("cat #{path}")['stdout']
    expect(conf).to eq(<<~CONF)
      [main]
      vardir = /var/lib/puppet
      logdir = /var/log/puppet
      rundir = /var/run/puppet
      ssldir = $vardir/ssl
      certname = node.example.com
      server = puppet.example.com
    CONF
  end

  it 'does not carry over other settings, or settings outside [main]' do
    seed("[main]\nserver = old.example.com\nruninterval = 1h\n[agent]\nvardir = /elsewhere\n")
    result = run_bolt_task('ovadm::configure_puppet_conf', { 'server' => 'puppet.example.com' })
    expect(result.result['kept']).to eq([])
    conf = run_shell("cat #{path}")['stdout']
    expect(conf).not_to include('old.example.com', 'runinterval', '/elsewhere')
  end

  it 'reflects the server value in the response' do
    result = run_bolt_task('ovadm::configure_puppet_conf', { 'server' => 'puppet.example.com' })
    expect(result.result['server']).to eq('puppet.example.com')
  end

  it 'reflects a provided certname in the response' do
    result = run_bolt_task('ovadm::configure_puppet_conf', {
      'certname' => 'mynode.example.com',
      'server'   => 'puppet.example.com',
    })
    expect(result.result['certname']).to eq('mynode.example.com')
  end

  it 'writes the environment to the agent section when given' do
    result = run_bolt_task('ovadm::configure_puppet_conf', {
      'server'      => 'puppet.example.com',
      'environment' => 'openvox9',
    })
    expect(result.exit_code).to eq(0)
    expect(result.result['environment']).to eq('openvox9')
    conf = run_shell("cat #{path}")['stdout']
    expect(conf).to match(/^\[agent\]\nenvironment = openvox9$/m)
  end

  it 'accepts a ca_server parameter without error' do
    result = run_bolt_task('ovadm::configure_puppet_conf', {
      'server'    => 'puppet.example.com',
      'ca_server' => 'ca.example.com',
    })
    expect(result.exit_code).to eq(0)
    expect(result.result['status']).to eq('success')
  end
end
