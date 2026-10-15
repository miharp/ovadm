# frozen_string_literal: true

require 'spec_helper'
require 'yaml'

RSpec.describe 'ovadm::set_csr_attributes task' do
  let(:path) { '/etc/puppetlabs/puppet/csr_attributes.yaml' }

  # What provisioning leaves on a host whose CA autosigns on a pre-shared key
  let(:site_file) do
    <<~YAML
      custom_attributes:
        challengePassword: s3cret
      extension_requests:
        pp_datacenter: dc1
    YAML
  end

  def seed(content)
    run_shell("mkdir -p #{File.dirname(path)}\ncat > #{path} <<'CSR'\n#{content}CSR\n")
  end

  def file_content
    run_shell("cat #{path}")['stdout']
  end

  # Every example starts on a host with no file.
  before { run_shell("rm -f #{path}") }

  context 'without a file' do
    it 'writes one with pp_role and returns success' do
      result = run_bolt_task('ovadm::set_csr_attributes', { 'pp_role' => 'openvox_compiler' })
      expect(result.exit_code).to eq(0)
      data = result.result
      expect(data['status']).to eq('success')
      expect(data['path']).to eq(path)
      expect(data['pp_role']).to eq('openvox_compiler')
      expect(data['action']).to eq('created')
      expect(file_content).to eq("extension_requests:\n  pp_role: 'openvox_compiler'\n")
    end

    it 'quotes the role, so YAML reads one like 1.10 as a string' do
      result = run_bolt_task('ovadm::set_csr_attributes', { 'pp_role' => '1.10' })
      expect(result.exit_code).to eq(0)
      expect(YAML.safe_load(file_content)).to eq('extension_requests' => { 'pp_role' => '1.10' })
    end
  end

  context 'with a file and no agent Ruby to merge with' do
    it 'fails and leaves the file as it is' do
      seed(site_file)
      result = run_bolt_task('ovadm::set_csr_attributes', { 'pp_role' => 'openvox_compiler' })
      expect(result.exit_code).to eq(1)
      expect(result.result['_error']['msg']).to include('/opt/puppetlabs/puppet/bin/ruby', 'left as it is')
      expect(file_content).to eq(site_file)
    end
  end

  context 'with a file and the agent Ruby' do
    ruby = '/opt/puppetlabs/puppet/bin/ruby'

    # The distribution's Ruby stands in for the agent's, linked where the task
    # looks for it. A real agent Ruby, if the container has one, is left alone.
    before(:context) do
      out = run_shell(<<~SH)
        set -e
        if command -v apt-get >/dev/null; then
          apt-get update -qq
          DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ruby >/dev/null
        else
          dnf install -y -q ruby rubygem-json rubygem-psych
        fi
        if [ ! -e #{ruby} ]; then
          mkdir -p #{File.dirname(ruby)}
          ln -s "$(command -v ruby)" #{ruby}
        fi
      SH
      raise "could not set up Ruby in the container: #{out}" unless out['exit_code']&.zero?
    end

    after(:context) { run_shell("if [ -L #{ruby} ]; then rm -f #{ruby}; fi") }

    it 'sets pp_role and keeps the rest of the file, owner and mode included' do
      seed(site_file)
      run_shell("chmod 0600 #{path}")
      result = run_bolt_task('ovadm::set_csr_attributes', { 'pp_role' => 'openvox_compiler' })
      expect(result.exit_code).to eq(0)
      expect(result.result).to include(
        'status' => 'success',
        'action' => 'merged',
        'kept'   => ['custom_attributes.challengePassword', 'extension_requests.pp_datacenter'],
      )
      expect(result.result).not_to have_key('previous_pp_role')
      expect(YAML.safe_load(file_content)).to eq(
        'custom_attributes'  => { 'challengePassword' => 's3cret' },
        'extension_requests' => { 'pp_datacenter' => 'dc1', 'pp_role' => 'openvox_compiler' },
      )
      expect(run_shell("stat -c %a #{path}")['stdout'].strip).to eq('600')
    end

    it 'replaces a role the file names by its OID and reports it' do
      seed("extension_requests:\n  1.3.6.1.4.1.34380.1.1.13: webserver\n")
      result = run_bolt_task('ovadm::set_csr_attributes', { 'pp_role' => 'openvox_compiler' })
      expect(result.exit_code).to eq(0)
      expect(result.result).to include('action' => 'merged', 'previous_pp_role' => 'webserver', 'kept' => [])
      expect(YAML.safe_load(file_content)).to eq('extension_requests' => { 'pp_role' => 'openvox_compiler' })
    end

    it 'does not rewrite a file that already has the role' do
      content = "# provisioned\n#{site_file}  pp_role: openvox_compiler\n"
      seed(content)
      result = run_bolt_task('ovadm::set_csr_attributes', { 'pp_role' => 'openvox_compiler' })
      expect(result.exit_code).to eq(0)
      expect(result.result['action']).to eq('unchanged')
      expect(file_content).to eq(content)
    end

    it 'refuses a file that is not YAML and leaves it as it is' do
      content = "extension_requests: [pp_role\n"
      seed(content)
      result = run_bolt_task('ovadm::set_csr_attributes', { 'pp_role' => 'openvox_compiler' })
      expect(result.exit_code).to eq(1)
      expect(result.result['_error']['msg']).to include('is not YAML', 'left as it is')
      expect(file_content).to eq(content)
    end

    it 'refuses a file with keys the agent rejects and leaves it as it is' do
      content = "extension_request:\n  pp_role: webserver\n"
      seed(content)
      result = run_bolt_task('ovadm::set_csr_attributes', { 'pp_role' => 'openvox_compiler' })
      expect(result.exit_code).to eq(1)
      expect(result.result['_error']['msg']).to include('extension_request', 'left as it is')
      expect(file_content).to eq(content)
    end
  end
end
