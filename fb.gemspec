# frozen_string_literal: true

require_relative "lib/freshbooks/version"

Gem::Specification.new do |s|
  s.name        = "freshbooks-cli"
  s.version     = FreshBooks::CLI::VERSION
  s.summary     = "FreshBooks time tracking CLI"
  s.description = "Manage FreshBooks time entries from the command line. Supports OAuth2 auth, interactive time logging with defaults, and monthly entry listings."
  s.authors     = ["parasquid"]
  s.email       = ["git@parasquid.com"]
  s.license     = "GPL-3.0-only"
  s.homepage    = "https://github.com/parasquid/freshbooks-cli"

  s.metadata    = {
    "source_code_uri" => "https://github.com/parasquid/freshbooks-cli",
    "bug_tracker_uri" => "https://github.com/parasquid/freshbooks-cli/issues"
  }

  s.required_ruby_version = ">= 3.0"

  s.files         = Dir["lib/**/*.rb", "bin/*"]
  s.bindir        = "bin"
  s.executables   = ["fb"]

  s.add_dependency "thor", "~> 1.3"
  s.add_dependency "httparty", ">= 0.24", "< 1.0"
  s.add_dependency "dotenv", "~> 3.1"

  s.add_development_dependency "rspec", "~> 3.12"
  s.add_development_dependency "rspec-given"
  s.add_development_dependency "webmock"
end
