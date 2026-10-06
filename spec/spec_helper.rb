# frozen_string_literal: true

require 'bolt_spec/run'
require 'ostruct'
require 'shellwords'

DOCKER_TARGET = 'docker://ovadm-acceptance'
MODULE_PARENT = File.expand_path('../..', __dir__)

module OvadmTaskHelper
  include BoltSpec::Run

  def bolt_config
    { 'modulepath' => [MODULE_PARENT] }
  end

  def bolt_inventory
    {
      'targets' => [{
        'uri'    => DOCKER_TARGET,
        'config' => { 'transport' => 'docker' }
      }]
    }
  end

  def run_bolt_task(task_name, params = {})
    results = run_task(task_name, DOCKER_TARGET, params)
    first   = results.first
    OpenStruct.new(
      exit_code: first['status'] == 'success' ? 0 : 1,
      result:    first['value']
    )
  end

  # Runs a shell script in the container. Bolt's docker transport runs a
  # command without a shell, so the script goes to bash.
  def run_shell(script)
    run_command("bash -c #{Shellwords.escape(script)}", DOCKER_TARGET).first['value']
  end
end

RSpec.configure do |config|
  config.formatter = :documentation
  config.color     = true
  config.include OvadmTaskHelper
end
