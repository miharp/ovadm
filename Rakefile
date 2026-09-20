# frozen_string_literal: true

require 'rspec/core/rake_task'

RSpec::Core::RakeTask.new(:acceptance) do |t|
  t.pattern = 'spec/acceptance/**/*_spec.rb'
end

RSpec::Core::RakeTask.new(:unit) do |t|
  t.pattern = 'spec/plans/**/*_spec.rb'
end

# module:build and module:push, used by the Release workflow. Optional so the
# test tasks still load when the release group is not installed.
begin
  require 'puppet_blacksmith/rake_tasks'
rescue LoadError
  # release group not installed
end

task default: :unit
