# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'ovadm::precheck task' do
  it 'returns a status field and a checks array' do
    result = run_bolt_task('ovadm::precheck', {})
    expect(result.exit_code).to eq(0)
    data = result.result
    expect(data).to include('status', 'checks')
    expect(data['checks']).to be_an(Array)
    expect(data['checks']).not_to be_empty
  end

  it 'includes the expected check names' do
    result = run_bolt_task('ovadm::precheck', {})
    names = result.result['checks'].map { |c| c['check'] }
    expect(names).to include('os_family', 'java', 'port_8140', 'firewall', 'ntp', 'memory')
  end

  it 'each check has a status and detail field' do
    result = run_bolt_task('ovadm::precheck', {})
    result.result['checks'].each do |c|
      expect(c).to include('check', 'status', 'detail')
      expect(%w[pass fail warn]).to include(c['status'])
    end
  end

  it 'passes the os_family check on a supported platform' do
    result = run_bolt_task('ovadm::precheck', {})
    os_check = result.result['checks'].find { |c| c['check'] == 'os_family' }
    expect(os_check['status']).to eq('pass')
  end

  it 'never fails the firewall check — a closed 8140 is a warning, not a blocker' do
    result = run_bolt_task('ovadm::precheck', {})
    fw_check = result.result['checks'].find { |c| c['check'] == 'firewall' }
    expect(%w[pass warn]).to include(fw_check['status'])
  end

  it 'never fails the java check for a host about to be upgraded' do
    result = run_bolt_task('ovadm::precheck', 'upgrade' => true)
    java_check = result.result['checks'].find { |c| c['check'] == 'java' }
    expect(%w[pass warn]).to include(java_check['status'])
  end

  it 'leaves the system java alone for a host about to get OpenVox 9, whose launcher picks its own' do
    result = run_bolt_task('ovadm::precheck', 'ovox_major' => 9)
    java_check = result.result['checks'].find { |c| c['check'] == 'java' }
    expect(java_check['status']).to eq('pass')
    expect(java_check['detail']).to match(/picks its Java through a launcher/)
  end

  describe 'the memory check' do
    def memory_check(result)
      result.result['checks'].find { |c| c['check'] == 'memory' }
    end

    def defaults_file
      run_shell('test -f /etc/debian_version && echo /etc/default/puppetserver || echo /etc/sysconfig/puppetserver')['stdout'].strip
    end

    # Runs the precheck with JAVA_ARGS set in the service's defaults file,
    # putting back whatever was there before.
    def precheck_with_java_args(java_args)
      file = defaults_file
      run_shell("mkdir -p #{File.dirname(file)}; if [ -e #{file} ]; then cp -p #{file} #{file}.ovadm-spec; fi; " \
                "echo 'JAVA_ARGS=\"#{java_args}\"' > #{file}")
      run_bolt_task('ovadm::precheck', {})
    ensure
      run_shell("if [ -e #{file}.ovadm-spec ]; then mv #{file}.ovadm-spec #{file}; else rm -f #{file}; fi")
    end

    it 'passes with the heap OpenVox Server ships' do
      check = memory_check(run_bolt_task('ovadm::precheck', {}))
      expect(check['status']).to eq('pass')
      expect(check['detail']).to match(/2048 MB heap/)
    end

    it 'fails when the configured heap needs more memory than the host has' do
      result = precheck_with_java_args('-Xms4096g -Xmx4096g')
      expect(result.result['status']).to eq('fail')
      expect(memory_check(result)['detail']).to match(/refuses to start with the 4194304 MB heap \(-Xmx4096g\)/)
    end

    it 'goes by the last -Xmx, as the JVM does' do
      check = memory_check(precheck_with_java_args('-Xmx4096g -Xms512m -Xmx512m'))
      expect(check['status']).to eq('pass')
      expect(check['detail']).to match(/512 MB heap \(-Xmx512m\)/)
    end
  end
end
