# frozen_string_literal: true

require 'spec_helper'

# Nothing listens on 8140 in the test container, so the task times out at
# once with max_wait 0, and these check what it says about why.
RSpec.describe 'ovadm::wait_until_service_ready task' do
  log = '/var/log/puppetlabs/puppetserver/puppetserver.log'

  # Runs the task with the given puppetserver.log contents (nil for no log),
  # putting back whatever was there before.
  def wait_with_log(log, content)
    run_shell("mkdir -p #{File.dirname(log)}; if [ -e #{log} ]; then mv #{log} #{log}.ovadm-spec; fi")
    run_shell("printf '%s\\n' #{content.map { |l| Shellwords.escape(l) }.join(' ')} > #{log}") if content
    run_bolt_task('ovadm::wait_until_service_ready', 'max_wait' => 0)
  ensure
    run_shell("rm -f #{log}; if [ -e #{log}.ovadm-spec ]; then mv #{log}.ovadm-spec #{log}; fi")
  end

  it 'reports the last error puppetserver logged, with its exception' do
    result = wait_with_log(log, [
      '2026-10-06T17:24:19.797Z INFO  [main] [p.t.internal] Starting services',
      '2026-10-06T17:24:19.797Z ERROR [async-mixed-1] [p.t.internal] Error during service init!!!',
      'java.lang.Error: Not enough available RAM (1,869MB) to safely accommodate the configured JVM heap size of 2,048MB.',
      '        at puppetlabs.services.master.master_core$validate_memory_requirements_BANG_.invokeStatic(master_core.clj:1201)',
    ])
    expect(result.exit_code).to eq(1)
    expect(result.result['status']).to eq('timeout')
    expect(result.result['_error']['msg']).to match(
      /did not answer .* Last error in .*: Error during service init!!! java.lang.Error: Not enough available RAM \(1,869MB\)/,
    )
  end

  it 'says so when the log has no error' do
    result = wait_with_log(log, nil)
    expect(result.exit_code).to eq(1)
    expect(result.result['status']).to eq('timeout')
    expect(result.result['service']).to eq('puppetserver')
    expect(result.result['_error']['msg']).to match(/No error in .*journalctl -u puppetserver/)
  end

  # A stand-in curl that answers for puppetserver only, so the wait moves on
  # to OpenVoxDB, which nothing answers for either.
  context 'with puppetdb=true' do
    before do
      run_shell(<<~'SH')
        printf '#!/bin/sh\ncase "$*" in *:8140/*) echo running;; esac\n' > /usr/local/sbin/curl
        chmod +x /usr/local/sbin/curl
        mkdir -p /etc/puppetlabs/puppetdb/conf.d
        printf '[jetty]\nport = 8085\nssl-port = 8086\n' > /etc/puppetlabs/puppetdb/conf.d/jetty.ini
      SH
    end
    after { run_shell('rm -f /usr/local/sbin/curl /etc/puppetlabs/puppetdb/conf.d/jetty.ini') }

    it 'waits for OpenVoxDB on the port jetty.ini names, and names it on a timeout' do
      result = run_bolt_task('ovadm::wait_until_service_ready', 'max_wait' => 5, 'puppetdb' => true)
      expect(result.exit_code).to eq(1)
      expect(result.result['status']).to eq('timeout')
      expect(result.result['service']).to eq('puppetdb')
      expect(result.result['_error']['msg']).to match(%r{puppetdb did not answer on http://localhost:8085 within 5 seconds .*journalctl -u puppetdb})
    end

    it 'is ready once both answer' do
      run_shell(%q(printf '#!/bin/sh\necho running\n' > /usr/local/sbin/curl))
      result = run_bolt_task('ovadm::wait_until_service_ready', 'max_wait' => 5, 'puppetdb' => true)
      expect(result.exit_code).to eq(0)
      expect(result.result).to eq('status' => 'ready', 'elapsed_seconds' => 0, 'services' => %w[puppetserver puppetdb])
    end
  end
end
