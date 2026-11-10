# frozen_string_literal: true

require 'spec_helper'

# ovadm::agent_disable and ovadm::agent_enable against a stand-in puppet that
# keeps the two lock files where the tests can see them, in the format the
# real agent writes: {"disabled_message":"..."} and a pid. A run under way is
# a run lock holding pid 1, which is always alive in the container.
RSpec.describe 'ovadm::agent_disable and ovadm::agent_enable tasks' do
  let(:disabled_lock) { '/tmp/fake-agent-disabled' }
  let(:run_lock)      { '/tmp/fake-agent-run' }

  def fake_puppet
    run_shell(<<~SH)
      cat > /usr/local/sbin/puppet <<'FAKE'
      #!/bin/bash
      echo "$*" >> /tmp/puppet.log
      case "$1 $2" in
        "config print") case "$3" in agent_disabled_lockfile) echo /tmp/fake-agent-disabled ;; agent_catalog_run_lockfile) echo /tmp/fake-agent-run ;; esac ;;
        "agent --disable") printf '{"disabled_message":"%s"}' "$3" > /tmp/fake-agent-disabled ;;
        "agent --enable") rm -f /tmp/fake-agent-disabled ;;
      esac
      exit 0
      FAKE
      chmod 0755 /usr/local/sbin/puppet
    SH
  end

  def agent_calls
    run_shell('cat /tmp/puppet.log 2>/dev/null || true')['stdout'].lines.map(&:strip).grep(/^agent /)
  end

  def exists?(path)
    run_shell("test -e #{path} && echo yes || echo no")['stdout'].strip == 'yes'
  end

  def disable_with(message)
    run_shell(%(printf '{"disabled_message":"%s"}' '#{message}' > #{disabled_lock}))
  end

  after do
    run_shell("rm -f /usr/local/sbin/puppet /tmp/puppet.log #{disabled_lock} #{run_lock}")
  end

  context 'without puppet' do
    it 'reports not_installed from both tasks' do
      result = run_bolt_task('ovadm::agent_disable')
      expect(result.exit_code).to eq(0)
      expect(result.result).to include('status' => 'not_installed', 'disabled_here' => false)

      result = run_bolt_task('ovadm::agent_enable')
      expect(result.exit_code).to eq(0)
      expect(result.result['status']).to eq('not_installed')
    end
  end

  context 'with puppet' do
    before { fake_puppet }

    it 'disables the agent with the message, and enables it again' do
      result = run_bolt_task('ovadm::agent_disable', 'message' => 'ovadm upgrade to 9.0.1 in progress')
      expect(result.exit_code).to eq(0)
      expect(result.result).to eq('status' => 'disabled', 'disabled_here' => true, 'message' => 'ovadm upgrade to 9.0.1 in progress', 'waited' => 0)
      expect(exists?(disabled_lock)).to be(true)

      result = run_bolt_task('ovadm::agent_enable', 'only_message' => 'ovadm upgrade')
      expect(result.exit_code).to eq(0)
      expect(result.result).to eq('status' => 'enabled', 'message' => 'ovadm upgrade to 9.0.1 in progress')
      expect(exists?(disabled_lock)).to be(false)
      expect(agent_calls).to eq(['agent --disable ovadm upgrade to 9.0.1 in progress', 'agent --enable'])
    end

    it 'uses a default message' do
      result = run_bolt_task('ovadm::agent_disable')
      expect(result.result).to include('status' => 'disabled', 'message' => 'ovadm operation in progress')
    end

    it 'leaves an agent the operator disabled as it is' do
      disable_with('maintenance, ask Sam')
      result = run_bolt_task('ovadm::agent_disable', 'message' => 'ovadm upgrade in progress', 'reclaim' => 'ovadm upgrade')
      expect(result.exit_code).to eq(0)
      expect(result.result).to eq('status' => 'already_disabled', 'disabled_here' => false, 'message' => 'maintenance, ask Sam', 'waited' => 0)
      expect(agent_calls).to eq([])
      expect(run_shell("cat #{disabled_lock}")['stdout']).to eq('{"disabled_message":"maintenance, ask Sam"}')
    end

    it 'takes over an agent an earlier run of the same operation left disabled' do
      disable_with('ovadm upgrade to 9.0.0 in progress')
      result = run_bolt_task('ovadm::agent_disable', 'message' => 'ovadm upgrade to 9.0.1 in progress', 'reclaim' => 'ovadm upgrade')
      expect(result.exit_code).to eq(0)
      expect(result.result).to eq('status' => 'reclaimed', 'disabled_here' => true, 'message' => 'ovadm upgrade to 9.0.0 in progress', 'waited' => 0)
      expect(agent_calls).to eq([])
    end

    it 'does not take over a matching message without reclaim' do
      disable_with('ovadm upgrade to 9.0.0 in progress')
      result = run_bolt_task('ovadm::agent_disable', 'message' => 'ovadm upgrade to 9.0.1 in progress')
      expect(result.result).to include('status' => 'already_disabled', 'disabled_here' => false)
    end

    it 'does not wait for a run lock whose process is gone' do
      run_shell("echo 999999 > #{run_lock}")
      result = run_bolt_task('ovadm::agent_disable')
      expect(result.exit_code).to eq(0)
      expect(result.result).to include('status' => 'disabled', 'waited' => 0)
    end

    it 'waits for a run under way to finish' do
      run_shell("echo 1 > #{run_lock}; setsid bash -c 'sleep 4; rm -f #{run_lock}' >/dev/null 2>&1 &")
      result = run_bolt_task('ovadm::agent_disable')
      expect(result.exit_code).to eq(0)
      expect(result.result).to include('status' => 'disabled', 'disabled_here' => true, 'waited' => 5)
    end

    it 'fails when the run does not finish in time, and does not leave the agent disabled' do
      run_shell("echo 1 > #{run_lock}")
      result = run_bolt_task('ovadm::agent_disable', 'max_wait' => 1)
      expect(result.exit_code).to eq(1)
      expect(result.result['_error']['kind']).to eq('ovadm/agent')
      expect(result.result['_error']['msg']).to eq('an agent run (pid 1) has not finished after 1 s; wait for it, then run this again')
      expect(exists?(disabled_lock)).to be(false)
      expect(agent_calls.last).to eq('agent --enable')
    end

    it 'keeps an operator\'s lock when the run does not finish in time' do
      disable_with('maintenance, ask Sam')
      run_shell("echo 1 > #{run_lock}")
      result = run_bolt_task('ovadm::agent_disable', 'max_wait' => 1)
      expect(result.exit_code).to eq(1)
      expect(exists?(disabled_lock)).to be(true)
      expect(agent_calls).to eq([])
    end

    it 'enable reports an agent that is not disabled' do
      result = run_bolt_task('ovadm::agent_enable')
      expect(result.exit_code).to eq(0)
      expect(result.result).to eq('status' => 'not_disabled', 'message' => nil)
      expect(agent_calls).to eq([])
    end

    it 'enable leaves alone an agent disabled with another message' do
      disable_with('maintenance, ask Sam')
      result = run_bolt_task('ovadm::agent_enable', 'only_message' => 'ovadm upgrade')
      expect(result.exit_code).to eq(0)
      expect(result.result).to eq('status' => 'left_disabled', 'message' => 'maintenance, ask Sam')
      expect(exists?(disabled_lock)).to be(true)
      expect(agent_calls).to eq([])
    end

    it 'enable without only_message enables whatever the message' do
      disable_with('maintenance, ask Sam')
      result = run_bolt_task('ovadm::agent_enable')
      expect(result.result).to eq('status' => 'enabled', 'message' => 'maintenance, ask Sam')
      expect(exists?(disabled_lock)).to be(false)
    end
  end
end
