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

  it 'removes nothing when the release package is already the one configured' do
    result = run_bolt_task('ovadm::configure_repo', {})
    expect(result.result['removed']).to eq([])
  end

  it 'points the repository at the public repository by default' do
    result = run_bolt_task('ovadm::configure_repo', {})
    expect(result.result['repository']).to match(%r{\Ahttps://(apt|yum)\.voxpupuli\.org(/|\z)})
  end

  describe 'with a mirror' do
    # A base URL with an explicit port is the public repository under another
    # name: the task can install from it, and the port in the repository file
    # shows that the file was pointed at the base URL given.
    after do
      run_shell("sed -i 's#voxpupuli.org:443#voxpupuli.org#' /etc/apt/sources.list.d/openvox8-release.list " \
                '/etc/yum.repos.d/openvox8-release.repo 2>/dev/null; true')
    end

    it 'downloads the release package from the mirror and points the repository file at it' do
      result = run_bolt_task('ovadm::configure_repo',
                             'apt_base_url' => 'https://apt.voxpupuli.org:443/',
                             'yum_base_url' => 'https://yum.voxpupuli.org:443/')
      expect(result.exit_code).to eq(0)
      expect(result.result['repo_url']).to include('voxpupuli.org:443/')
      expect(result.result['repository']).to include('voxpupuli.org:443')

      urls = run_shell("cat #{result.result['repository_file']}")['stdout'].scan(%r{https://\S+})
      expect(urls).not_to be_empty
      expect(urls).to all(include('voxpupuli.org:443'))
    end
  end
end
