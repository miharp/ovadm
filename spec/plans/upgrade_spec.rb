# frozen_string_literal: true

require_relative 'spec_helper'

describe 'ovadm::upgrade' do
  let(:server)         { 'ovox-server.example.com' }
  let(:compiler)       { 'ovox-compiler01.example.com' }
  let(:server_version) { '8.13.0' }

  before(:each) { execute_no_plan }

  context 'Standard topology (no compiler_hosts)' do
    it 'runs precheck and upgrade_server only' do
      expect_plan('ovadm::subplans::precheck').be_called_times(1)
      expect_plan('ovadm::subplans::upgrade_server').be_called_times(1)
      allow_plan('ovadm::subplans::upgrade_compilers').not_be_called

      result = run_plan('ovadm::upgrade', {
        'server_host'         => server,
        'ovox_server_version' => server_version
      })
      expect(result).to be_ok
    end
  end

  context 'Large topology (with compiler_hosts)' do
    it 'also runs upgrade_compilers' do
      expect_plan('ovadm::subplans::precheck').be_called_times(1)
      expect_plan('ovadm::subplans::upgrade_server').be_called_times(1)
      expect_plan('ovadm::subplans::upgrade_compilers').be_called_times(1)

      result = run_plan('ovadm::upgrade', {
        'server_host'         => server,
        'ovox_server_version' => server_version,
        'compiler_hosts'      => compiler
      })
      expect(result).to be_ok
    end
  end

end
