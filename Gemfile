source 'https://rubygems.org'

ruby '>= 3.2'

gem 'openbolt', require: false
gem 'rake'
gem 'rspec'

# Required for net-ssh ed25519 key support (used by openbolt's SSH transport)
gem 'ed25519', '>= 1.2', '< 2.0'
gem 'bcrypt_pbkdf', '>= 1.0', '< 2.0'

# Builds the Forge tarball (rake module:build) and uploads it (rake module:push).
group :release do
  gem 'puppet-blacksmith', '~> 9.1', require: false
  gem 'metadata-json-lint', '~> 5.0', require: false
end
