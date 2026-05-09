# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'ovadm::agent_runonce task' do
  it 'returns a status field' do
    result = run_bolt_task('ovadm::agent_runonce', {})
    expect(result.exit_code).to eq(0)
    expect(result.result).to include('status')
  end

  it 'returns not_installed when the puppet binary is absent' do
    result = run_bolt_task('ovadm::agent_runonce', {})
    expect(result.result['status']).to eq('not_installed')
  end
end
