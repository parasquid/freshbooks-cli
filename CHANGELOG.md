# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.3] - 2026-03-04

### Added
- Per-client and per-service hour breakdowns in `fb entries` totals
- Local dates in entries table (instead of UTC timestamps)

## [0.3.2] - 2026-03-04

### Added
- GitHub Actions workflow to auto-release gem on version bump

## [0.3.1] - 2026-03-04

### Added
- `--interactive` flag to force interactive mode in non-TTY contexts
- Word-wrapping for notes in `fb entries` table output (replaces 50-char truncation)

### Changed
- Spinner output moved to stderr and suppressed in non-interactive mode
- Spinner now respects `--interactive` / `--no-interactive` flags instead of checking TTY independently
- FreshBooks skill: `--service` is now treated as required when logging time

## [0.3.0] - 2026-03-04

### Added
- `fb business` command to list and select active business
- `fb auth` subcommands for non-interactive auth: `setup`, `url`, `callback`, `status`
- Interactive detection via `$stdin.tty?` + `--no-interactive` flag
- `--format json` on all mutation commands (`log`, `edit`, `delete`)
- `--format json` on `status` and `cache status`
- `--service` flag for `fb log` and `fb edit` (project-scoped services)
- Service column in `fb entries` table output
- Non-interactive mode: auto-selects single options, aborts with clear errors for ambiguous choices
- Docker timezone pass-through from host
- Claude Code skill for agent-driven time tracking

### Fixed
- `started_at` date format (API requires full datetime, not bare date)
- `fb edit` now preserves all existing fields (API replaces entire entry on PUT)
- `build_name_maps` extracts services from project data (global endpoint returns empty)
- `fb cache status` correctly counts project-scoped services

## [0.2.1] - 2026-03-04

### Added
- `fb version` subcommand to print the current version

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

## [0.1.0] - 2026-03-03

Initial release.

### Added
- OAuth2 authentication with FreshBooks Developer Apps
- Interactive time entry logging with client, project, and service selection
- Defaults saved from last log entry for faster repeat logging
- `entries` command to list time entries in table or JSON format
- `help --format json` for machine-readable command documentation
- Docker-based workflow with bind-mounted config directory

[0.3.0]: https://github.com/parasquid/freshbooks-cli/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/parasquid/freshbooks-cli/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/parasquid/freshbooks-cli/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/parasquid/freshbooks-cli/releases/tag/v0.1.0
