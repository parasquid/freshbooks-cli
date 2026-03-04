# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-03-04

### Added
- rspec-given test suite covering Auth, Api, Cli, and Spinner modules
- OAuth scope validation — verifies granted scopes on authorization
- Loading spinner with braille animation for long-running operations
- Date range filtering for `entries` command (`--from`, `--to`, `--month`, `--year`)
- Inline OAuth authorization flow (no separate browser callback server)
- Rakefile with bundler gem tasks for release workflow

### Changed
- `log` and `entries` commands now validate the access token upfront instead of deferring to API calls

### Fixed
- HTTParty SSRF vulnerability (CVE-2025-68696)
- Gemspec metadata for RubyGems publishing
- Docker Compose wrapper no longer prints noisy service logs

## [0.1.0] - 2025-01-01

Initial release.

### Added
- OAuth2 authentication with FreshBooks Developer Apps
- Interactive time entry logging with client, project, and service selection
- Defaults saved from last log entry for faster repeat logging
- `entries` command to list time entries in table or JSON format
- `help --format json` for machine-readable command documentation
- Docker-based workflow with bind-mounted config directory

[0.2.0]: https://github.com/parasquid/freshbooks-cli/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/parasquid/freshbooks-cli/releases/tag/v0.1.0
