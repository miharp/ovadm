# frozen_string_literal: true

require 'spec_helper'

# The task drives `puppetserver ca generate`, so the bare container can only
# show that it refuses a host without one. What it does on a real server is
# checked in .github/workflows/install-test.yml.
RSpec.describe 'ovadm::server_cert_regen task' do
  it 'fails on a host without puppetserver, and says so' do
    result = run_bolt_task('ovadm::server_cert_regen')
    expect(result.exit_code).to eq(1)
    expect(result.result['_error']).to include('kind' => 'ovadm/server-cert-regen', 'msg' => 'puppetserver is not installed on this host.')
  end
end
