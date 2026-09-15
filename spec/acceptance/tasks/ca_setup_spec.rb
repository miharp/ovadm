# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'ovadm::ca_setup task' do
  it 'returns not_installed when puppetserver is absent' do
    result = run_bolt_task('ovadm::ca_setup', {})
    expect(result.exit_code).to eq(0)
    expect(result.result['status']).to eq('not_installed')
  end

  it 'still returns not_installed when alt names are given' do
    result = run_bolt_task('ovadm::ca_setup', { 'subject_alt_names' => 'puppet,ovox-lb.example.com' })
    expect(result.exit_code).to eq(0)
    expect(result.result['status']).to eq('not_installed')
  end
end
