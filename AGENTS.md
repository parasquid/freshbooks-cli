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
- **Api** (`lib/fb/api.rb`) — FreshBooks REST client. All HTTP goes through HTTParty. Paginated fetching via `fetch_all_pages`. Name maps (client/project/service ID → name) cached for 10 minutes in `cache.json`. Services are project-scoped — `build_name_maps` extracts them from project data, not just the global services endpoint.
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

- `fb auth setup` — writes credentials to `~/.fb/.env` (interactive: prompts with masked secret; non-interactive: reads from `FRESHBOOKS_CLIENT_ID`/`FRESHBOOKS_CLIENT_SECRET` env vars or `~/.fb/.env`)
- `fb auth url` — prints OAuth URL
- `fb auth callback REDIRECT_URL` — exchanges code for tokens, auto-selects single business
- `fb auth status` — shows current auth state
- `fb business --select ID` — sets active business (required for multi-business accounts)

### Credential Storage

- **`~/.fb/.env`** — stores `FRESHBOOKS_CLIENT_ID` and `FRESHBOOKS_CLIENT_SECRET`. Never written to `config.json`.
- **`~/.fb/config.json`** — stores `business_id` and `account_id` only. Credentials are stripped before writing.
- **`load_config`** — merges ENV credentials (loaded from `~/.fb/.env` via dotenv) with `config.json` (business info). Returns the full config hash for all callers.
- **`save_config`** — always strips `client_id`/`client_secret` before writing so they can never land in `config.json`.
- **Migration** — if `config.json` contains `client_id`/`client_secret` from an older install, `load_dotenv` moves them to `~/.fb/.env` and strips them from `config.json` silently on every startup.

### Dry-Run Mode

All commands support `--dry-run` (global class option). When set:

- Auth is bypassed — `valid_access_token` returns `"dry-run-token"`, `require_config` reads config.json directly without requiring credentials
- Read API calls use cached data ignoring freshness (stale cache is acceptable); if cache is empty, reads return `[]`
- Write API calls (`create_time_entry`, `update_time_entry`, `delete_time_entry`) return mock responses without hitting the network
- A `[DRY RUN] No changes will be made.` banner is printed to stderr before the command runs
- With `--format json`, all output is wrapped with `"_dry_run": {"simulated": true}` metadata; array results are nested under `"data"`

Implementation uses `Thread.current[:fb_dry_run]` set in `invoke_command` with `ensure` cleanup. Dry-run guards are added as the first line of ~8 leaf methods in `Auth` and `Api`. All business logic (name map building, pagination, caching) runs unchanged through the same code paths.

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

## Branch & PR Naming

- **Branches:** `{issue-number}-{issue-title}` (GitHub default convention, title converted to lowercase with hyphens). Example: `4-secure-credential-input`
- **PR titles:** `type(scope): description` (Conventional Commits style). Example: `feat(auth): add env var credential input`

## Planning & Issue Tracking

- Design specs and implementation plans go in `docs/plans/` — nowhere else.
- When creating a plan, the first task should be updating the related GitHub issue with the full contents of the design spec only (not the implementation plan, not just links).
- If there is no GitHub issue for the work, suggest creating one and upload the plan to the newly created issue.
- The last task in a plan should be updating or creating ALL related documentation: README, AGENTS.md, and any skill files (e.g. `skills/*/SKILL.md`) that reference changed behavior or conventions.

## Skills

- **FreshBooks** (`skills/freshbooks/SKILL.md`) — Time tracking via the `fb` CLI. Auto-activates for time tracking queries.

## Superpowers Overrides

- **Plans location:** Save all design specs and implementation plans to `docs/plans/` (overrides the skill default of `docs/superpowers/plans/`)

## FreshBooks API Gotchas

- **Services are project-scoped.** The global `/comments/business/{id}/services` endpoint often returns empty. Services are embedded in project JSON under the `services` array. Use `fb projects --format json` to see available services per project.
- **Dates must be full datetimes.** The API rejects bare dates like `"2026-03-04"` — use `"2026-03-04T00:00:00Z"`. The CLI's `normalize_datetime` helper handles this.
- **PUT replaces, not patches.** Updating a time entry replaces the entire record. The `edit` command sends all existing fields (client_id, project_id, service_id, duration, note, started_at, is_logged) alongside any changed fields to avoid wiping data.
