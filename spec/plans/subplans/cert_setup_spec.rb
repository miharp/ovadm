# frozen_string_literal: true

require_relative '../spec_helper'

describe 'ovadm::subplans::cert_setup' do
  let(:server)   { 'ovox-server.example.com' }
  let(:compiler) { 'ovox-compiler01.example.com' }
  let(:params) do
    { 'server_host' => server, 'compiler_hosts' => compiler }
  end

  before(:each) do
    allow_command('hostname -f').always_return('stdout' => "#{compiler}\n", 'stderr' => '')
  end

  it 'sets csr_attributes, submits CSR, signs it, and runs agent to apply catalog' do
    expect_task('ovadm::set_csr_attributes')
      .with_params('pp_role' => 'openvox_compiler')
      .be_called_times(1)
      .always_return('status' => 'success')
    expect_task('ovadm::agent_runonce').be_called_times(2).always_return('status' => 'no_changes', 'exit_code' => 0)
    expect_task('ovadm::sign_csr').be_called_times(1).always_return('status' => 'signed', 'certname' => compiler)

    result = run_plan('ovadm::subplans::cert_setup', params)
    expect(result).to be_ok
  end

  it 'passes openvox_compiler as the pp_role value' do
    allow_task('ovadm::set_csr_attributes').always_return('status' => 'success')
    allow_task('ovadm::agent_runonce').always_return('status' => 'no_changes', 'exit_code' => 0)
    allow_task('ovadm::sign_csr').always_return('status' => 'signed', 'certname' => compiler)

    expect_task('ovadm::set_csr_attributes').with_params('pp_role' => 'openvox_compiler')

    run_plan('ovadm::subplans::cert_setup', params)
  end

  context 'when the first catalog run applies nothing' do
    let(:compiler02) { 'ovox-compiler02.example.com' }

    before(:each) do
      allow_task('ovadm::set_csr_attributes').always_return('status' => 'success')
      allow_task('ovadm::sign_csr').always_return('status' => 'already_signed')
    end

    it 'fails the plan, naming the compiler and the agent exit code' do
      allow_task('ovadm::agent_runonce').always_return('status' => 'failed', 'exit_code' => 1)

      result = run_plan('ovadm::subplans::cert_setup', params)
      expect(result).not_to be_ok
      expect(result.value.message).to match(/applied no catalog on 1 of 1 compiler/)
      expect(result.value.message).to match(/#{compiler}: puppet agent exited 1 on its first catalog run/)
      expect(result.value.message).to match(/ovadm::add_compiler for the same compilers finishes the job/)
      expect(result.value.message).not_to match(/Check that the environment/)
    end

    it 'points at the environment when one was given' do
      allow_task('ovadm::agent_runonce').always_return('status' => 'failed', 'exit_code' => 1, 'environment' => 'notyet')

      result = run_plan('ovadm::subplans::cert_setup', params.merge('environment' => 'notyet'))
      expect(result).not_to be_ok
      expect(result.value.message).to match(/Check that the environment notyet is deployed on the server/)
    end

    it 'reports a run that found no agent' do
      allow_task('ovadm::agent_runonce').always_return('status' => 'not_installed')

      result = run_plan('ovadm::subplans::cert_setup', params)
      expect(result).not_to be_ok
      expect(result.value.message).to match(/#{compiler}: agent_runonce reported not_installed/)
    end

    it 'sets up every compiler before failing, and names only the one that failed' do
      allow_command('hostname -f').return_for_targets(
        compiler   => { 'stdout' => "#{compiler}\n", 'stderr' => '' },
        compiler02 => { 'stdout' => "#{compiler02}\n", 'stderr' => '' },
      )
      allow_task('ovadm::agent_runonce').with_params('waitforcert' => 0).always_return('status' => 'failed', 'exit_code' => 1)
      allow_task('ovadm::agent_runonce').with_params({}).return_for_targets(
        compiler   => { 'status' => 'changes_applied', 'exit_code' => 2 },
        compiler02 => { 'status' => 'failed', 'exit_code' => 4 },
      )
      expect_task('ovadm::sign_csr').with_params('certname' => compiler).be_called_times(1).always_return('status' => 'signed')
      expect_task('ovadm::sign_csr').with_params('certname' => compiler02).be_called_times(1).always_return('status' => 'signed')

      result = run_plan('ovadm::subplans::cert_setup', params.merge('compiler_hosts' => [compiler, compiler02]))
      expect(result).not_to be_ok
      expect(result.value.message).to match(/on 1 of 2 compiler/)
      expect(result.value.message).to match(/#{compiler02}: puppet agent exited 4/)
      expect(result.value.message).not_to match(/#{compiler}: /)
    end
  end

  it 'accepts a submit run that failed for want of a certificate' do
    allow_task('ovadm::set_csr_attributes').always_return('status' => 'success')
    allow_task('ovadm::sign_csr').always_return('status' => 'signed')
    allow_task('ovadm::agent_runonce').with_params('waitforcert' => 0).always_return('status' => 'failed', 'exit_code' => 1)
    allow_task('ovadm::agent_runonce').with_params({}).always_return('status' => 'changes_applied', 'exit_code' => 2)

    expect(run_plan('ovadm::subplans::cert_setup', params)).to be_ok
  end

  context 'without an environment' do
    it 'runs the agent without --environment' do
      allow_task('ovadm::set_csr_attributes').always_return('status' => 'success')
      allow_task('ovadm::sign_csr').always_return('status' => 'signed', 'certname' => compiler)
      expect_task('ovadm::agent_runonce')
        .with_params('waitforcert' => 0)
        .be_called_times(1)
        .always_return('status' => 'no_changes', 'exit_code' => 0)
      expect_task('ovadm::agent_runonce')
        .with_params({})
        .be_called_times(1)
        .always_return('status' => 'changes_applied', 'exit_code' => 2)

      result = run_plan('ovadm::subplans::cert_setup', params)
      expect(result).to be_ok
    end
  end

  context 'with an environment' do
    # Both runs must ask for it: the server assigns production when the
    # environment in puppet.conf does not exist yet, and the agent then keeps
    # the assigned environment over the configured one on every later run.
    it 'passes it to both agent runs' do
      allow_task('ovadm::set_csr_attributes').always_return('status' => 'success')
      allow_task('ovadm::sign_csr').always_return('status' => 'signed', 'certname' => compiler)
      expect_task('ovadm::agent_runonce')
        .with_params('waitforcert' => 0, 'environment' => 'demo')
        .be_called_times(1)
        .always_return('status' => 'no_changes', 'exit_code' => 0, 'environment' => 'demo')
      expect_task('ovadm::agent_runonce')
        .with_params('environment' => 'demo')
        .be_called_times(1)
        .always_return('status' => 'changes_applied', 'exit_code' => 2, 'environment' => 'demo')

      result = run_plan('ovadm::subplans::cert_setup', params.merge('environment' => 'demo'))
      expect(result).to be_ok
    end
  end
end
