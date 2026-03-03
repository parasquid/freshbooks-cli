# frozen_string_literal: true

require_relative "lib/fb/version"

Gem::Specification.new do |s|
  s.name        = "freshbooks-cli"
  s.version     = FB::VERSION
  s.summary     = "FreshBooks time tracking CLI"
  s.description = "Manage FreshBooks time entries from the command line. Supports OAuth2 auth, interactive time logging with defaults, and monthly entry listings."
  s.authors     = ["Tristan"]
  s.license     = "GPL-3.0"
  s.homepage    = "https://github.com/tristan/freshbooks-cli"

  s.required_ruby_version = ">= 3.0"

  s.files         = Dir["lib/**/*.rb", "bin/*"]
  s.bindir        = "bin"
  s.executables   = ["fb"]

  s.add_dependency "thor", "~> 1.3"
  s.add_dependency "httparty", ">= 0.24", "< 1.0"
end
