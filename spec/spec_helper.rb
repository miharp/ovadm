# frozen_string_literal: true

require 'bolt_spec/run'
require 'ostruct'

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
end

RSpec.configure do |config|
  config.formatter = :documentation
  config.color     = true
  config.include OvadmTaskHelper
end
