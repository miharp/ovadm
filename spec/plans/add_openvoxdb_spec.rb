# frozen_string_literal: true

require_relative 'spec_helper'

describe 'ovadm::add_openvoxdb' do
  let(:server) { 'ovox-server.example.com' }
  let(:pdb)    { 'ovox-pdb.example.com' }

  before(:each) { execute_no_plan }

  context 'co-located (no puppetdb_host specified)' do
    it 'calls the openvoxdb subplan once' do
      expect_plan('ovadm::subplans::openvoxdb').be_called_times(1)

      result = run_plan('ovadm::add_openvoxdb', {
        'server_host' => server,
        'db_password' => 's3cret'
      })
      expect(result).to be_ok
    end
  end

  context 'separate puppetdb_host' do
    it 'calls the openvoxdb subplan once with the pdb target' do
      expect_plan('ovadm::subplans::openvoxdb').be_called_times(1)

      result = run_plan('ovadm::add_openvoxdb', {
        'server_host'   => server,
        'puppetdb_host' => pdb,
        'db_password'   => 's3cret'
      })
      expect(result).to be_ok
    end
  end
end
