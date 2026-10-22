# frozen_string_literal: true

require 'spec_helper'

# A small package from the distribution's own repositories stands in for
# openvoxdb-termini.
RSpec.describe 'ovadm::install_package task' do
  let(:pkg) { 'tree' }

  before(:context) { run_shell('if command -v apt-get >/dev/null; then apt-get update -qq; fi; true') }
  after(:context) { run_shell('if command -v apt-get >/dev/null; then apt-get remove -y -q tree >/dev/null 2>&1; else dnf remove -y -q tree >/dev/null 2>&1; fi; true') }

  it 'installs a package, then reports it already installed at that version' do
    result = run_bolt_task('ovadm::install_package', { 'name' => pkg })
    expect(result.exit_code).to eq(0)
    expect(result.result['status']).to eq('installed')
    version = result.result['version']
    expect(version).not_to be_empty

    result = run_bolt_task('ovadm::install_package', { 'name' => pkg, 'version' => version })
    expect(result.result).to eq('status' => 'already_installed', 'package' => pkg, 'version' => version)
  end

  it 'fails plainly on a version the repositories do not have' do
    result = run_bolt_task('ovadm::install_package', { 'name' => pkg, 'version' => '0.0.0-nope' })
    expect(result.exit_code).to eq(1)
    expect(result.result['_error']['msg']).to match(/could not install tree[-=]0\.0\.0-nope/)
  end
end
