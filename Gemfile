source 'https://rubygems.org'

ruby '>= 3.2'

gem 'openbolt', require: false
gem 'rake'
gem 'rspec'

# Required for net-ssh ed25519 key support (used by openbolt's SSH transport)
gem 'ed25519', '>= 1.2', '< 2.0'
gem 'bcrypt_pbkdf', '>= 1.0', '< 2.0'

group :test do
  gem 'metadata-json-lint', '~> 5.0', require: false
end

# Generates REFERENCE.md from the plan and task documentation
# (rake strings:generate:reference).
group :development do
  gem 'openvox-strings', '~> 7.0', require: false
end

# Same release tooling as miharp/puppet-headscale: rake module:build and
# module:push, run by the shared Vox Pupuli release workflow.
group :release do
  gem 'voxpupuli-release', '~> 5.4', require: false
end
