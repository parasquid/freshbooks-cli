# AGENTS.md

This file provides guidance to AI coding agents when working with code in this repository.

## Build & Test Commands

```bash
# Run full test suite via Docker
docker compose build
docker compose run --rm --entrypoint rspec fb

# Run a single spec file
docker compose run --rm --entrypoint rspec fb spec/fb/auth_spec.rb

# Run locally (requires Ruby >= 3.0)
gem build fb.gemspec && gem install freshbooks-cli-*.gem
rspec

# Release (bumps tag, pushes gem to RubyGems)
rake release
```

## Architecture

The gem is a single-module CLI (`FB`) built on Thor, with four components:

- **Auth** (`lib/fb/auth.rb`) — OAuth2 flow, token management, config/cache/defaults persistence. All state stored as JSON files in `Auth.data_dir` (`~/.fb/` or `.fb/` in Docker). Tests redirect this to a tmpdir. Provides both interactive (`setup_config`, `authorize`, `discover_business`) and non-interactive (`setup_config_from_args`, `authorize_url`, `extract_code_from_url`, `exchange_code`, `fetch_businesses`, `select_business`, `auth_status`) methods.
- **Api** (`lib/fb/api.rb`) — FreshBooks REST client. All HTTP goes through HTTParty. Paginated fetching via `fetch_all_pages`. Name maps (client/project ID → name) cached for 10 minutes in `cache.json`.
- **Cli** (`lib/fb/cli.rb`) — Thor subclass. Commands: `auth`, `business`, `log`, `entries`, `clients`, `projects`, `services`, `status`, `edit`, `delete`, `cache`, `help`, `version`. Interactive prompts read from `$stdin`. Interactive detection via `$stdin.tty?` + `--no-interactive` flag.
- **Spinner** (`lib/fb/spinner.rb`) — Braille animation spinner. Yields to a block, returns block result. Globally stubbed in tests to just yield.

### Interactive Detection

The CLI uses `interactive?` to decide whether to prompt:

```ruby
def interactive?
  return false if options[:no_interactive]
  $stdin.tty?
end
```

- **TTY detected** (terminal): prompts for missing values with defaults
- **No TTY** (pipes, agents, CI): uses flags, auto-selects single options, or aborts with clear errors
- `--no-interactive` flag forces non-interactive mode

### Auth Flow

Auth supports both interactive (single `fb auth` command) and non-interactive (subcommands) flows:

- `fb auth setup --client-id ID --client-secret SECRET` — saves config
- `fb auth url` — prints OAuth URL
- `fb auth callback REDIRECT_URL` — exchanges code for tokens, auto-selects single business
- `fb auth status` — shows current auth state
- `fb business --select ID` — sets active business (required for multi-business accounts)

### JSON Output

All commands support `--format json` (global class option). Mutation commands (`log`, `edit`, `delete`) return the API response or structured confirmation. Read commands return data arrays or structured summaries.

## Testing Conventions

- **rspec-given** style: `Given`/`When`/`Then` blocks, not `describe`/`it`/`expect`
- `Failure(SystemExit)` for testing `abort` calls
- **webmock** stubs HTTP at the socket level — never stub HTTParty directly
- **File I/O** uses real files in a tmpdir (spec_helper sets `Auth.data_dir` per test)
- **Spinner** is stubbed globally in `spec_helper` to just yield (no threads in tests)
- **$stdin** stubbed with `allow($stdin).to receive(:gets).and_return(...)` or `allow($stdin).to receive(:tty?).and_return(false)` for non-interactive tests

## Key Patterns

- All modules use `class << self` (singleton methods only, no instances)
- Config, tokens, defaults, cache are all separate JSON files under `Auth.data_dir`
- `Auth.data_dir=` is the seam for test isolation — point it at a tmpdir
- Docker wrapper (`./fb`) runs CLI in container with `.fb/` bind-mounted and host `TZ` passed through
