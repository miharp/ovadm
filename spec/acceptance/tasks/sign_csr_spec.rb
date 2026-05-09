# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'ovadm::sign_csr task' do
  it 'returns not_installed when puppetserver is absent' do
    result = run_bolt_task('ovadm::sign_csr', { 'certname' => 'test.example.com' })
    expect(result.exit_code).to eq(0)
    expect(result.result['status']).to eq('not_installed')
  end
end
