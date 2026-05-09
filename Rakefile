# frozen_string_literal: true

require 'rspec/core/rake_task'

RSpec::Core::RakeTask.new(:acceptance) do |t|
  t.pattern = 'spec/acceptance/**/*_spec.rb'
end

RSpec::Core::RakeTask.new(:unit) do |t|
  t.pattern = 'spec/plans/**/*_spec.rb'
end

task default: :unit
