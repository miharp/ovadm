# frozen_string_literal: true

require_relative '../spec_helper'

describe 'ovadm::subplans::upgrade_compilers' do
  let(:compiler)       { 'ovox-compiler01.example.com' }
  let(:server_version) { '8.13.0' }
  let(:params) do
    { 'compiler_hosts' => compiler, 'ovox_server_version' => server_version, 'ovox_major' => 8 }
  end

  before(:each) do
    allow_task('ovadm::get_version').always_return('version' => '8.12.1-1.el9', 'package' => 'openvox-server')
    allow_task('ovadm::configure_repo').always_return('status' => 'success')
    allow_task('ovadm::install_server').always_return('status' => 'success', 'version' => server_version)
    allow_task('ovadm::select_java').always_return('status' => 'unchanged')
    allow_task('ovadm::service_restart').always_return('status' => 'success')
    allow_task('ovadm::wait_until_service_ready').always_return('status' => 'success')
  end

  it 'installs the server, selects Java, restarts, and waits for readiness on compilers' do
    expect_task('ovadm::configure_repo').not_be_called
    expect_task('ovadm::install_server').be_called_times(1)
    expect_task('ovadm::select_java').be_called_times(1)
    expect_task('ovadm::service_restart').be_called_times(1)
    expect_task('ovadm::wait_until_service_ready').be_called_times(1)

    result = run_plan('ovadm::subplans::upgrade_compilers', params)
    expect(result).to be_ok
  end

  it 'switches the repository first when moving to a new major version' do
    expect_task('ovadm::configure_repo').with_params('ovox_major' => 9).be_called_times(1)

    result = run_plan('ovadm::subplans::upgrade_compilers', params.merge('ovox_server_version' => '9.0.0', 'ovox_major' => 9))
    expect(result).to be_ok
  end

  context 'with several compilers' do
    let(:compilers) { %w[ovox-compiler01.example.com ovox-compiler02.example.com ovox-compiler03.example.com] }
    let(:params) do
      { 'compiler_hosts' => compilers, 'ovox_server_version' => server_version, 'ovox_major' => 8 }
    end

    # Each step, in the order the plan ran it, with the hosts it ran on.
    let(:calls) { [] }

    def record(step)
      allow_task("ovadm::#{step}").return do |targets:, task:, params:| # rubocop:disable Lint/UnusedBlockArgument
        calls << [step, targets.map(&:name)]
        Bolt::ResultSet.new(targets.map { |target| Bolt::Result.new(target, value: { 'status' => 'success' }) })
      end
    end

    # Fail one task on one host, and record the call like the others.
    def fail_on(step, host)
      allow_task("ovadm::#{step}").return do |targets:, task:, params:| # rubocop:disable Lint/UnusedBlockArgument
        calls << [step, targets.map(&:name)]
        Bolt::ResultSet.new(targets.map do |target|
          if target.name == host
            Bolt::Result.new(target, error: { 'msg' => 'puppetserver did not start', 'kind' => 'ovadm/service', 'details' => {} })
          else
            Bolt::Result.new(target, value: { 'status' => 'success' })
          end
        end)
      end
    end

    let(:steps) { %w[install_server select_java service_restart wait_until_service_ready] }

    before(:each) { steps.each { |step| record(step) } }

    it 'runs each step on all of them at once by default' do
      result = run_plan('ovadm::subplans::upgrade_compilers', params)

      expect(result).to be_ok
      expect(calls).to eq(steps.map { |step| [step, compilers] })
    end

    it 'takes them one at a time with rolling, each ready before the next is touched' do
      compilers.each_with_index do |name, index|
        expect_out_message.with_params("Upgrading compiler #{name} (#{index + 1} of 3).")
      end

      result = run_plan('ovadm::subplans::upgrade_compilers', params.merge('rolling' => true))

      expect(result).to be_ok
      expect(calls).to eq(compilers.flat_map { |name| steps.map { |step| [step, [name]] } })
    end

    it 'switches the repository one compiler at a time too' do
      expect_task('ovadm::configure_repo').with_params('ovox_major' => 9).be_called_times(3)

      result = run_plan('ovadm::subplans::upgrade_compilers',
                        params.merge('rolling' => true, 'ovox_server_version' => '9.0.0', 'ovox_major' => 9))
      expect(result).to be_ok
    end

    it 'stops at a compiler that fails, and says which ones it did not touch' do
      fail_on('service_restart', compilers[1])
      expect_out_message.with_params("Compiler #{compilers[1]} failed: puppetserver did not start")
      expect_out_message.with_params(
        "The plan stops here. Upgraded before it: #{compilers[0]}. " \
        "Not touched, and still on the version they had: #{compilers[2]}."
      )

      result = run_plan('ovadm::subplans::upgrade_compilers', params.merge('rolling' => true))

      expect(result).not_to be_ok
      expect(result.value.msg).to eq("run_task 'ovadm::service_restart' failed on 1 target")
      expect(calls.map(&:last).flatten.uniq).to eq(compilers[0, 2])
      expect(calls.last).to eq(['service_restart', [compilers[1]]])
    end

    it 'says so when the first compiler fails' do
      fail_on('install_server', compilers[0])
      expect_out_message.with_params("Compiler #{compilers[0]} failed: puppetserver did not start")
      expect_out_message.with_params(
        'The plan stops here. No compiler was upgraded before it. ' \
        "Not touched, and still on the version they had: #{compilers[1]}, #{compilers[2]}."
      )

      result = run_plan('ovadm::subplans::upgrade_compilers', params.merge('rolling' => true))
      expect(result).not_to be_ok
    end

    it 'says so when the last compiler fails' do
      fail_on('wait_until_service_ready', compilers[2])
      expect_out_message.with_params("Compiler #{compilers[2]} failed: puppetserver did not start")
      expect_out_message.with_params(
        "The plan stops here. Upgraded before it: #{compilers[0]}, #{compilers[1]}. It was the last one."
      )

      result = run_plan('ovadm::subplans::upgrade_compilers', params.merge('rolling' => true))
      expect(result).not_to be_ok
    end

    it 'gives the plan error as the reason when a subplan fails' do
      allow_plan('ovadm::subplans::upgrade_repo').error_with('msg' => 'no release package for openvox9', 'kind' => 'ovadm/repo')
      expect_out_message.with_params("Compiler #{compilers[0]} failed: no release package for openvox9")

      result = run_plan('ovadm::subplans::upgrade_compilers', params.merge('rolling' => true))
      expect(result).not_to be_ok
      expect(calls).to eq([])
    end

    it 'fails with the task error, and no rolling message, when a step fails without rolling' do
      fail_on('service_restart', compilers[1])

      result = run_plan('ovadm::subplans::upgrade_compilers', params)

      expect(result).not_to be_ok
      expect(result.value.msg).to eq("run_task 'ovadm::service_restart' failed on 1 target")
      expect(calls.last).to eq(['service_restart', compilers])
    end
  end
end
