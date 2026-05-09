# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'ovadm::get_version task' do
  it 'returns a version field' do
    result = run_bolt_task('ovadm::get_version', {})
    expect(result.exit_code).to eq(0)
    expect(result.result).to include('version')
  end

  it 'returns not_installed when openvox-server is absent' do
    result = run_bolt_task('ovadm::get_version', {})
    expect(result.result['version']).to eq('not_installed')
  end
end
