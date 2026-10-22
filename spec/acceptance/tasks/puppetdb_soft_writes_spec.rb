# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'ovadm::puppetdb_soft_writes task' do
  let(:conf) { '/etc/puppetlabs/puppet/puppetdb.conf' }
  let(:original) { "[main]\nserver_urls = https://nowhere.invalid:8081/\nsoft_write_failure = false\n" }

  before { run_shell("install -d /etc/puppetlabs/puppet; rm -f #{conf} #{conf}.ovadm-restore") }

  it 'reports no puppetdb.conf when there is none' do
    expect(run_bolt_task('ovadm::puppetdb_soft_writes').result['status']).to eq('no_puppetdb_conf')
  end

  it 'enables soft writes when OpenVoxDB does not answer, keeping a copy, and puts the copy back' do
    run_shell("printf '#{original}' > #{conf}; chmod 0640 #{conf}")
    data = run_bolt_task('ovadm::puppetdb_soft_writes').result
    expect(data).to include('status' => 'enabled', 'path' => conf, 'copy' => "#{conf}.ovadm-restore", 'url' => 'https://nowhere.invalid:8081/')
    expect(run_shell("cat #{conf}")['stdout']).to eq("[main]\nserver_urls = https://nowhere.invalid:8081/\nsoft_write_failure = true\n")
    expect(run_shell("cat #{conf}.ovadm-restore")['stdout']).to eq(original)

    # Twice is still one copy of the original.
    run_bolt_task('ovadm::puppetdb_soft_writes', { 'mode' => 'enable' })
    expect(run_shell("cat #{conf}.ovadm-restore")['stdout']).to eq(original)

    data = run_bolt_task('ovadm::puppetdb_soft_writes', { 'mode' => 'restore' }).result
    expect(data['status']).to eq('restored')
    expect(run_shell("cat #{conf}")['stdout']).to eq(original)
    expect(run_shell("stat -c %a #{conf}")['stdout'].strip).to eq('640')
    expect(run_shell("test -e #{conf}.ovadm-restore && echo yes || echo no")['stdout'].strip).to eq('no')
    expect(run_bolt_task('ovadm::puppetdb_soft_writes', { 'mode' => 'restore' }).result['status']).to eq('nothing_to_restore')
  end

  it 'adds the setting under [main] when the file has none' do
    run_shell("printf '[main]\\nserver_urls = https://nowhere.invalid:8081/\\n' > #{conf}")
    run_bolt_task('ovadm::puppetdb_soft_writes', { 'mode' => 'enable' })
    expect(run_shell("cat #{conf}")['stdout']).to eq("[main]\nsoft_write_failure = true\nserver_urls = https://nowhere.invalid:8081/\n")
  end
end
