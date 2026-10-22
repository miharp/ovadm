# frozen_string_literal: true

require_relative 'spec_helper'
require 'tempfile'

describe 'ovadm::restore' do
  let(:server) { 'ovox.example.com' }
  let(:archive) { '/var/backups/openvox/openvox-backup-ovox.example.com-20261021T180000Z.tar.gz' }

  let(:verified) do
    {
      'status' => 'ok', 'archive' => archive, 'name' => File.basename(archive, '.tar.gz'),
      'created' => '2026-10-21T18:00:00Z', 'certname' => server, 'files' => 12,
      'checksums' => { 'checked' => 15, 'failed' => [] },
      'host' => { 'certname' => server, 'certname_matches' => true, 'packages' => {} },
      'problems' => [], 'warnings' => []
    }
  end

  let(:restored) do
    {
      'status' => 'restored', 'archive' => archive, 'certname' => server, 'scope' => %w[ca config code],
      'in_scope' => 12, 'changed' => ['/etc/puppetlabs/puppetserver/conf.d/webserver.conf'], 'missing' => [], 'unchanged' => 11,
      'ca' => { 'live_ca_differs' => false, 'signed_after_backup' => [] },
      'services_stopped' => %w[puppetserver puppetdb],
      'missing_gems' => { 'puppetserver' => [], 'agent' => [] }, 'warnings' => []
    }
  end

  let(:agent_ok) { { 'status' => 'changes_applied', 'exit_code' => 2, 'environment' => '' } }

  def allow_rest
    allow_command('systemctl start puppetserver').always_return('stdout' => '', 'stderr' => '')
    allow_task('ovadm::wait_until_service_ready').always_return('status' => 'ready', 'elapsed_seconds' => 5)
    allow_command('test -x /opt/puppetlabs/puppet/bin/r10k').always_return('stdout' => '', 'stderr' => '')
    allow_command('/opt/puppetlabs/puppet/bin/r10k deploy environment --modules').always_return('stdout' => '', 'stderr' => '')
    allow_task('ovadm::agent_runonce').always_return(agent_ok)
    allow_task('ovadm::puppetdb_soft_writes').with_params('mode' => 'enable_if_unreachable').always_return('status' => 'not_needed', 'path' => '/etc/puppetlabs/puppet/puppetdb.conf', 'url' => 'https://ovox.example.com:8081/')
    allow_task('ovadm::puppetdb_soft_writes').with_params('mode' => 'restore').always_return('status' => 'nothing_to_restore', 'path' => '/etc/puppetlabs/puppet/puppetdb.conf')
    allow_plan('ovadm::status').always_return({})
  end

  it 'on a rebuilt host, installs the termini package and makes PuppetDB writes non-fatal for the agent run' do
    allow_task('ovadm::backup_verify').always_return(verified.merge('host' => verified['host'].merge(
      'packages' => { 'openvoxdb-termini' => { 'archive' => '8.17.0-1.el10', 'host' => nil } }
    )))
    allow_task('ovadm::backup_restore').always_return(restored)
    allow_rest
    expect_task('ovadm::install_package').with_params('name' => 'openvoxdb-termini', 'version' => '8.17.0-1.el10')
                                         .always_return('status' => 'installed', 'package' => 'openvoxdb-termini', 'version' => '8.17.0-1.el10', 'previous' => nil)
    expect_task('ovadm::puppetdb_soft_writes').with_params('mode' => 'enable_if_unreachable')
                                              .always_return('status' => 'enabled', 'path' => '/etc/puppetlabs/puppet/puppetdb.conf', 'copy' => '/etc/puppetlabs/puppet/puppetdb.conf.ovadm-restore', 'url' => 'https://ovox.example.com:8081/')
    expect_task('ovadm::puppetdb_soft_writes').with_params('mode' => 'restore').always_return('status' => 'restored', 'path' => '/etc/puppetlabs/puppet/puppetdb.conf')
    expect_task('ovadm::service_restart').be_called_times(2).always_return('status' => 'restarted', 'service' => 'puppetserver')
    expect_task('ovadm::wait_until_service_ready').be_called_times(3).always_return('status' => 'ready', 'elapsed_seconds' => 0)
    expect_out_message.with_params("#{server}: installed openvoxdb-termini 8.17.0-1.el10, which the manifest lists and the host lacked")
    expect_out_message.with_params("#{server}: OpenVoxDB at https://ovox.example.com:8081/ does not answer; PuppetDB writes made non-fatal in puppetdb.conf for the agent run")
    expect_out_message.with_params("#{server}: puppetdb.conf put back as archived")

    expect(run_plan('ovadm::restore', { 'server_host' => server, 'archive' => archive })).to be_ok
  end

  it 'leaves the termini package alone when the host has it, and puppetdb.conf alone when OpenVoxDB answers' do
    allow_task('ovadm::backup_verify').always_return(verified.merge('host' => verified['host'].merge(
      'packages' => { 'openvoxdb-termini' => { 'archive' => '8.17.0-1.el10', 'host' => '8.17.0-1.el10' } }
    )))
    allow_task('ovadm::backup_restore').always_return(restored)
    allow_rest
    expect_task('ovadm::install_package').not_be_called
    expect_task('ovadm::service_restart').not_be_called

    expect(run_plan('ovadm::restore', { 'server_host' => server, 'archive' => archive })).to be_ok
  end

  it 'verifies, restores everything, starts the server, redeploys code, runs the agent and reports status' do
    expect_task('ovadm::backup_verify').with_params('archive' => archive).always_return(verified)
    expect_task('ovadm::backup_restore').with_params('archive' => archive, 'force' => false, 'dry_run' => false).always_return(restored)
    expect_command('systemctl start puppetserver').always_return('stdout' => '', 'stderr' => '')
    expect_task('ovadm::wait_until_service_ready').be_called_times(2).always_return('status' => 'ready', 'elapsed_seconds' => 5)
    expect_command('/opt/puppetlabs/puppet/bin/r10k deploy environment --modules').be_called_times(1).always_return('stdout' => '', 'stderr' => '')
    allow_command('test -x /opt/puppetlabs/puppet/bin/r10k').always_return('stdout' => '', 'stderr' => '')
    expect_task('ovadm::agent_runonce').with_params('waitforcert' => 0).always_return(agent_ok)
    allow_task('ovadm::puppetdb_soft_writes').with_params('mode' => 'enable_if_unreachable').always_return('status' => 'not_needed', 'path' => '/etc/puppetlabs/puppet/puppetdb.conf', 'url' => 'https://ovox.example.com:8081/')
    allow_task('ovadm::puppetdb_soft_writes').with_params('mode' => 'restore').always_return('status' => 'nothing_to_restore', 'path' => '/etc/puppetlabs/puppet/puppetdb.conf')
    expect_plan('ovadm::status').be_called_times(1).always_return({})
    expect_out_message.with_params("#{server}: scope ca, config, code: 1 file(s) changed, 0 missing on the host, 11 unchanged")
    expect_out_message.with_params("#{server}: puppetserver and puppetdb stopped for the copy and started again")

    result = run_plan('ovadm::restore', { 'server_host' => server, 'archive' => archive })
    expect(result).to be_ok
    expect(result.value.keys).to contain_exactly('verify', 'restore', 'agent', 'status')
  end

  it 'passes scope, force and the age identity through' do
    expect_task('ovadm::backup_verify').with_params('archive' => "#{archive}.age", 'age_identity' => '/root/k').always_return(verified)
    expect_task('ovadm::backup_restore').with_params(
      'archive' => "#{archive}.age", 'force' => true, 'dry_run' => false, 'age_identity' => '/root/k', 'scope' => 'ca,extra'
    ).always_return(restored.merge('scope' => %w[ca extra]))
    expect_command('/opt/puppetlabs/puppet/bin/r10k deploy environment --modules').not_be_called
    allow_rest

    result = run_plan('ovadm::restore', {
      'server_host' => server, 'archive' => "#{archive}.age", 'scope' => %w[ca extra], 'force' => true, 'age_identity' => '/root/k'
    })
    expect(result).to be_ok
  end

  it 'uploads the archive from the workstation first when given a source' do
    source = Tempfile.new(['openvox-backup', '.tar.gz'])
    expect_command("install -d -m 0700 '/var/backups/openvox'").with_targets(server).always_return('stdout' => '', 'stderr' => '')
    expect_upload(source.path).with_destination(archive).with_targets(server)
    expect_task('ovadm::backup_verify').with_params('archive' => archive).always_return(verified)
    allow_task('ovadm::backup_restore').always_return(restored)
    allow_rest
    expect_out_message.with_params("#{server}: uploaded #{source.path} to #{archive}")

    result = run_plan('ovadm::restore', { 'server_host' => server, 'archive' => archive, 'source' => source.path })
    expect(result).to be_ok
  ensure
    source&.close!
  end

  it 'stops after reporting with dry_run' do
    allow_task('ovadm::backup_verify').always_return(verified)
    expect_task('ovadm::backup_restore').with_params('archive' => archive, 'force' => false, 'dry_run' => true)
                                        .always_return(restored.merge('status' => 'dry_run', 'services_stopped' => [], 'missing' => ['/etc/puppetlabs/puppet/autosign.conf']))
    expect_command('systemctl start puppetserver').not_be_called
    expect_task('ovadm::agent_runonce').not_be_called
    expect_plan('ovadm::status').not_be_called
    expect_out_message.with_params("#{server}: scope ca, config, code: 1 file(s) would change, 1 missing on the host, 11 unchanged")
    expect_out_message.with_params('  /etc/puppetlabs/puppetserver/conf.d/webserver.conf')
    expect_out_message.with_params('  /etc/puppetlabs/puppet/autosign.conf')

    result = run_plan('ovadm::restore', { 'server_host' => server, 'archive' => archive, 'dry_run' => true })
    expect(result).to be_ok
    expect(result.value.keys).to contain_exactly('verify', 'restore')
  end

  it 'fails when the archive does not verify, after printing the problems' do
    allow_task('ovadm::backup_verify').always_return(verified.merge(
      'status' => 'failed', 'problems' => ['1 file(s) do not match their checksum: files/etc/puppetlabs/puppetserver/ca/ca_key.pem']
    ))
    expect_task('ovadm::backup_restore').not_be_called
    expect_out_message.with_params("ERROR #{server}: 1 file(s) do not match their checksum: files/etc/puppetlabs/puppetserver/ca/ca_key.pem")

    result = run_plan('ovadm::restore', { 'server_host' => server, 'archive' => archive })
    expect(result).not_to be_ok
    expect(result.value.msg).to include('did not verify')
  end

  it 'lets force past a certname mismatch, but not past a bad checksum' do
    allow_task('ovadm::backup_verify').always_return(verified.merge(
      'status' => 'failed', 'problems' => ['the archive is from other.example.com, this host is ovox.example.com']
    ))
    allow_task('ovadm::backup_restore').always_return(restored)
    allow_rest
    expect(run_plan('ovadm::restore', { 'server_host' => server, 'archive' => archive, 'force' => true })).to be_ok
    expect(run_plan('ovadm::restore', { 'server_host' => server, 'archive' => archive })).not_to be_ok
  end

  it 'reinstalls the gems the manifest lists and the host lacks, and reports a failure' do
    allow_task('ovadm::backup_verify').always_return(verified)
    allow_task('ovadm::backup_restore').always_return(restored.merge('missing_gems' => { 'puppetserver' => ['hocon-1.4.0'], 'agent' => ['hiera-eyaml-5.0.1'] }))
    expect_command('puppetserver gem install --no-document hocon -v 1.4.0').always_return('stdout' => '', 'stderr' => '')
    expect_command('/opt/puppetlabs/puppet/bin/gem install --no-document hiera-eyaml -v 5.0.1').error_with('msg' => 'boom', 'kind' => 'puppetlabs.tasks/command-error')
    expect_out_message.with_params("#{server}: installed puppetserver gem hocon-1.4.0")
    expect_out_message.with_params("WARNING #{server}: agent gem hiera-eyaml-5.0.1 could not be installed: boom")
    allow_rest

    expect(run_plan('ovadm::restore', { 'server_host' => server, 'archive' => archive })).to be_ok
  end

  it 'warns when the agent run after the restore fails, and still reports status' do
    allow_task('ovadm::backup_verify').always_return(verified)
    allow_task('ovadm::backup_restore').always_return(restored)
    allow_rest
    allow_task('ovadm::agent_runonce').always_return('status' => 'failed', 'exit_code' => 1, 'environment' => '')
    expect_task('ovadm::wait_until_service_ready').be_called_times(2).always_return('status' => 'ready', 'elapsed_seconds' => 0)
    expect_plan('ovadm::status').be_called_times(1).always_return({})
    expect_out_message.with_params("WARNING #{server}: the agent run after the restore failed (exit 1); the files are back and the services are up. Run puppet agent -t on the server to see why")

    result = run_plan('ovadm::restore', { 'server_host' => server, 'archive' => archive })
    expect(result).to be_ok
    expect(result.value['agent']['status']).to eq('failed')
  end

  it 'skips the agent run and the code deploy when told, and when r10k is absent' do
    allow_task('ovadm::backup_verify').always_return(verified)
    allow_task('ovadm::backup_restore').always_return(restored)
    allow_rest
    allow_command('test -x /opt/puppetlabs/puppet/bin/r10k').error_with('msg' => 'no', 'kind' => 'puppetlabs.tasks/command-error')
    expect_command('/opt/puppetlabs/puppet/bin/r10k deploy environment --modules').not_be_called
    expect_task('ovadm::agent_runonce').not_be_called
    expect_out_message.with_params("#{server}: r10k is not installed; the code directory is as the archive holds it")

    result = run_plan('ovadm::restore', { 'server_host' => server, 'archive' => archive, 'agent_run' => false })
    expect(result).to be_ok
    expect(result.value['agent']).to be_nil
  end
end
