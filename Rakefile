# frozen_string_literal: true

require 'rspec/core/rake_task'

RSpec::Core::RakeTask.new(:acceptance) do |t|
  t.pattern = 'spec/acceptance/**/*_spec.rb'
end

RSpec::Core::RakeTask.new(:unit) do |t|
  t.pattern = 'spec/plans/**/*_spec.rb'
end

begin
  require 'puppet-strings/tasks'
rescue LoadError
  # openvox-strings is only available in the development gem group
end

begin
  require 'voxpupuli/release/rake_tasks'
rescue LoadError
  # voxpupuli-release is only available in the release gem group
else
  GCGConfig.user = 'miharp'
  GCGConfig.project = 'ovadm'
end

task default: :unit
