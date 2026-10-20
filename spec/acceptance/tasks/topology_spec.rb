# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'ovadm::topology task' do
  let(:result) { run_bolt_task('ovadm::topology', {}) }

  it 'succeeds and reports the fields the status plan reads' do
    expect(result.exit_code).to eq(0)
    expect(result.result).to include('certname', 'ca', 'server_role', 'compilers', 'openvoxdb', 'postgresql')
    expect(result.result['openvoxdb']).to include('server_urls', 'version', 'database')
    expect(result.result['postgresql']).to include('version', 'pg_dump')
  end

  it 'reports the certname and no compilers on a lone server' do
    expect(result.result['certname']).not_to be_empty
    expect(result.result['compilers']).to eq([])
    expect([true, false]).to include(result.result['ca'])
  end
end
