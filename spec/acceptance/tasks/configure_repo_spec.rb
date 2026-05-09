# frozen_string_literal: true

require 'spec_helper'

# These tests download from apt.voxpupuli.org and require network access.
RSpec.describe 'ovadm::configure_repo task' do
  it 'configures the OpenVox repository and returns success' do
    result = run_bolt_task('ovadm::configure_repo', {})
    expect(result.exit_code).to eq(0)
    data = result.result
    expect(data['status']).to eq('success')
  end

  it 'returns a repo_url pointing to voxpupuli.org' do
    result = run_bolt_task('ovadm::configure_repo', {})
    expect(result.result['repo_url']).to include('voxpupuli.org')
  end
end
