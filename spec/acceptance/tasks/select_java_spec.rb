# frozen_string_literal: true

require 'spec_helper'

# The test containers have no openvox-server; selecting a Java against a real
# install is covered by the Puppet 7 upgrade job in install-test.yml.
RSpec.describe 'ovadm::select_java task' do
  it 'fails when openvox-server is not installed' do
    result = run_bolt_task('ovadm::select_java', {})
    expect(result.exit_code).to eq(1)
    expect(result.result.to_s).to include('openvox-server is not installed')
  end
end
