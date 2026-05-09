# frozen_string_literal: true

require_relative 'spec_helper'

describe 'ovadm::install' do
  let(:server)   { 'ovox-primary.example.com' }
  let(:compiler) { 'ovox-compiler01.example.com' }

  before(:each) { execute_no_plan }

  def standard_stubs
    allow_plan('ovadm::subplans::precheck').always_return(nil)
    allow_plan('ovadm::subplans::install').always_return(nil)
    allow_plan('ovadm::subplans::configure').always_return(nil)
    allow_task('ovadm::wait_until_service_ready').always_return({})
  end

  context 'Standard topology (no compiler_hosts)' do
    it 'runs precheck, install, configure, and waits for service' do
      expect_plan('ovadm::subplans::precheck').be_called_times(1)
      expect_plan('ovadm::subplans::install').be_called_times(1)
      expect_plan('ovadm::subplans::configure').be_called_times(1)
      expect_task('ovadm::wait_until_service_ready').be_called_times(1)

      result = run_plan('ovadm::install', { 'server_host' => server })
      expect(result).to be_ok
    end
  end

  context 'Large topology (with compiler_hosts)' do
    it 'adds precheck, agent_install, and cert_setup for compilers' do
      expect_plan('ovadm::subplans::precheck').be_called_times(2)
      expect_plan('ovadm::subplans::install').be_called_times(1)
      expect_plan('ovadm::subplans::configure').be_called_times(1)
      expect_task('ovadm::wait_until_service_ready').be_called_times(1)
      expect_plan('ovadm::subplans::agent_install').be_called_times(1)
      expect_plan('ovadm::subplans::cert_setup').be_called_times(1)

      allow_command('hostname -f').always_return('stdout' => "#{server}\n", 'stderr' => '')

      result = run_plan('ovadm::install', {
        'server_host'    => server,
        'compiler_hosts' => compiler
      })
      expect(result).to be_ok
    end
  end
end
