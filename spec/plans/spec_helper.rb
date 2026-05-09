# frozen_string_literal: true

require 'bolt_spec/plans'

# Parent directory of the repo — Bolt finds the `ovadm` module here because
# the repo directory itself is named `ovadm`. No fixture symlink required.
MODULE_PARENT = File.expand_path('../../..', __dir__)

# Override BoltSpec::BoltContext#modulepath so plan specs find the ovadm
# module without needing rspec-puppet or a spec/fixtures symlink.
module OvadmBoltContext
  def modulepath
    [MODULE_PARENT]
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
