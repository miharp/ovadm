# frozen_string_literal: true

require 'puppet_litmus/rake_tasks'
require 'puppetlabs_spec_helper/rake_tasks'
require 'rspec/core/rake_task'

RSpec::Core::RakeTask.new(:acceptance) do |t|
  t.pattern = 'spec/acceptance/**/*_spec.rb'
  t.rspec_opts = '--format documentation'
end

task default: :acceptance
