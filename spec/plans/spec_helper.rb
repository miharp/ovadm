# frozen_string_literal: true

require 'bolt_spec/plans'

FIXTURES_MODULES = File.expand_path('../fixtures/modules', __dir__)

# Override BoltSpec::BoltContext#modulepath so plan specs find the ovadm
# module under spec/fixtures/modules without needing rspec-puppet.
module OvadmBoltContext
  def modulepath
    [FIXTURES_MODULES]
  end
end

RSpec.configure do |config|
  config.formatter = :documentation
  config.color     = true
  config.include BoltSpec::Plans
  config.include OvadmBoltContext
  config.before(:each) { allow_out_message }
end

BoltSpec::Plans.init
