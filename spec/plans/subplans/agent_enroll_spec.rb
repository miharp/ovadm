# frozen_string_literal: true

require_relative '../spec_helper'

describe 'ovadm::subplans::agent_enroll' do
  let(:server)  { 'ovox-server.example.com' }
  let(:agent01) { 'agent01.example.com' }
  let(:agent02) { 'agent02.example.com' }
  let(:params)  { { 'agent_hosts' => [agent01, agent02], 'server_host' => server } }

  before(:each) do
    allow_command('hostname -f').return_for_targets(
      agent01 => { 'stdout' => "#{agent01}\n", 'stderr' => '' },
      agent02 => { 'stdout' => "#{agent02}\n", 'stderr' => '' },
    )
    allow_task('ovadm::agent_runonce').always_return('status' => 'changes_applied', 'exit_code' => 2)
    allow_task('ovadm::sign_csr').always_return('status' => 'signed')
  end

  it 'submits the CSRs, signs each on the server and runs every agent once more' do
    expect_task('ovadm::agent_runonce').with_targets([agent01, agent02]).with_params('waitforcert' => 0, '_catch_errors' => true).be_called_times(1)
    expect_task('ovadm::sign_csr').with_targets(server).with_params('certname' => agent01, '_catch_errors' => true).be_called_times(1)
    expect_task('ovadm::sign_csr').with_targets(server).with_params('certname' => agent02, '_catch_errors' => true).be_called_times(1)
    expect_task('ovadm::agent_runonce').with_targets([agent01, agent02]).with_params('_catch_errors' => true).be_called_times(1)

    result = run_plan('ovadm::subplans::agent_enroll', params)
    expect(result).to be_ok
    expect(result.value['ok']).to eq([agent01, agent02])
    expect(result.value['failed']).to eq({})
  end

  it 'passes the environment to both agent runs' do
    expect_task('ovadm::agent_runonce').with_params('waitforcert' => 0, 'environment' => 'demo', '_catch_errors' => true).be_called_times(1)
    expect_task('ovadm::agent_runonce').with_params('environment' => 'demo', '_catch_errors' => true).be_called_times(1)

    result = run_plan('ovadm::subplans::agent_enroll', params.merge('environment' => 'demo'))
    expect(result).to be_ok
  end

  it 'accepts a certificate the CA already signed' do
    allow_task('ovadm::sign_csr').always_return('status' => 'already_signed')

    result = run_plan('ovadm::subplans::agent_enroll', params)
    expect(result).to be_ok
    expect(result.value['ok']).to eq([agent01, agent02])
  end

  it 'drops a host whose CSR the CA could not sign and goes on with the rest' do
    expect_task('ovadm::sign_csr').with_params('certname' => agent01, '_catch_errors' => true).always_return('status' => 'signed')
    expect_task('ovadm::sign_csr').with_params('certname' => agent02, '_catch_errors' => true)
      .error_with('msg' => "No certificate request found for #{agent02}", 'kind' => 'puppetlabs.tasks/task-error')
    expect_task('ovadm::agent_runonce').with_targets([agent01, agent02]).with_params('waitforcert' => 0, '_catch_errors' => true)
    expect_task('ovadm::agent_runonce').with_targets([agent01]).with_params('_catch_errors' => true)
      .be_called_times(1).always_return('status' => 'no_changes', 'exit_code' => 0)

    result = run_plan('ovadm::subplans::agent_enroll', params)
    expect(result).to be_ok
    expect(result.value['ok']).to eq([agent01])
    expect(result.value['failed']).to eq(agent02 => "No certificate request found for #{agent02}")
  end

  it 'reports a host whose first run applied nothing' do
    expect_task('ovadm::agent_runonce').with_params('waitforcert' => 0, '_catch_errors' => true).always_return('status' => 'failed', 'exit_code' => 1)
    expect_task('ovadm::agent_runonce').with_params('_catch_errors' => true).return_for_targets(
      agent01 => { 'status' => 'no_changes', 'exit_code' => 0 },
      agent02 => { 'status' => 'failed', 'exit_code' => 1 },
    )

    result = run_plan('ovadm::subplans::agent_enroll', params)
    expect(result).to be_ok
    expect(result.value['ok']).to eq([agent01])
    expect(result.value['failed'][agent02]).to match(/exited 1 on its first run/)
  end

  it 'counts only a run that applied a catalog, not one that found no agent' do
    expect_task('ovadm::agent_runonce').with_params('_catch_errors' => true).return_for_targets(
      agent01 => { 'status' => 'changes_applied', 'exit_code' => 2 },
      agent02 => { 'status' => 'not_installed', 'error' => 'puppet not installed' },
    )

    result = run_plan('ovadm::subplans::agent_enroll', params)
    expect(result).to be_ok
    expect(result.value['ok']).to eq([agent01])
    expect(result.value['failed']).to eq(agent02 => 'agent_runonce reported not_installed on the first run')
  end

  it 'does nothing with no hosts' do
    expect_task('ovadm::agent_runonce').not_be_called
    expect_task('ovadm::sign_csr').not_be_called

    result = run_plan('ovadm::subplans::agent_enroll', params.merge('agent_hosts' => []))
    expect(result).to be_ok
    expect(result.value).to eq('ok' => [], 'failed' => {})
  end
end
