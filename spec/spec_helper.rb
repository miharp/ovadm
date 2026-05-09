# frozen_string_literal: true

require 'puppet_litmus'
include PuppetLitmus # rubocop:disable Style/MixinUsage

RSpec.configure do |config|
  config.formatter = :documentation
  config.color = true
end
