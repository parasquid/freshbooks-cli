# AGENTS.md

This file provides guidance to AI coding agents when working with code in this repository.

## Build & Test Commands

```bash
# Run full test suite via Docker
docker compose build
docker compose run --rm --entrypoint rspec fb

# Run a single spec file
docker compose run --rm --entrypoint rspec fb spec/freshbooks/auth_spec.rb

# Run locally (requires Ruby >= 3.0)
gem build fb.gemspec && gem install freshbooks-cli-*.gem
rspec

# Release (bumps tag, pushes gem to RubyGems)
rake release
```

## Architecture

The gem is a CLI (`FreshBooks::CLI`) built on Thor, with four components:

- **Auth** (`lib/freshbooks/auth.rb`) — OAuth2 flow, token management, config/cache/defaults persistence. All state stored as JSON files in `FreshBooks::CLI::Auth.data_dir` (see resolution order below). Tests redirect this to a tmpdir. Provides both interactive (`setup_config`, `authorize`, `discover_business`) and non-interactive (`setup_config_from_args`, `authorize_url`, `extract_code_from_url`, `exchange_code`, `fetch_businesses`, `select_business`, `auth_status`) methods.
- **Api** (`lib/freshbooks/api.rb`) — FreshBooks REST client. All HTTP goes through HTTParty. Paginated fetching via `fetch_all_pages`. Name maps (client/project/service ID → name) cached for 10 minutes in `cache.json`. Services are project-scoped — `build_name_maps` extracts them from project data, not just the global services endpoint.
- **Commands** (`lib/freshbooks/cli.rb`) — Thor subclass (`FreshBooks::CLI::Commands`). Commands: `auth`, `business`, `log`, `entries`, `clients`, `projects`, `services`, `status`, `edit`, `delete`, `cache`, `help`, `version`. Interactive prompts read from `$stdin`. Interactive detection via `$stdin.tty?` + `--no-interactive` flag.
- **Spinner** (`lib/freshbooks/spinner.rb`) — Braille animation spinner. Yields to a block, returns block result. Globally stubbed in tests to just yield.

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

- `fb auth setup` — writes credentials to `<data_dir>/.env` (interactive: prompts with masked secret; non-interactive: reads from `FRESHBOOKS_CLIENT_ID`/`FRESHBOOKS_CLIENT_SECRET` env vars or `<data_dir>/.env`)
- `fb auth url` — prints OAuth URL
- `fb auth callback REDIRECT_URL` — exchanges code for tokens, auto-selects single business
- `fb auth status` — shows current auth state
- `fb business --select ID` — sets active business (required for multi-business accounts)

### Config Directory Resolution

`FreshBooks::CLI::Auth.data_dir` resolves in this order (first match wins):

1. `FRESHBOOKS_HOME` env var — explicit override, highest priority
2. `~/.fb` if it already exists — legacy migration path, preserves existing installs
3. macOS: `~/Library/Application Support/freshbooks`
4. Linux/other: `$XDG_CONFIG_HOME/freshbooks` (or `~/.config/freshbooks` if `XDG_CONFIG_HOME` is unset)

The `data_dir=` setter still works for test isolation — point it at a tmpdir. Setting it to `nil` resets to auto-resolution.

### Credential Storage

- **`<data_dir>/.env`** — stores `FRESHBOOKS_CLIENT_ID` and `FRESHBOOKS_CLIENT_SECRET`. Never written to `config.json`.
- **`<data_dir>/config.json`** — stores `business_id` and `account_id` only. Credentials are stripped before writing.
- **`load_config`** — merges ENV credentials (loaded from `<data_dir>/.env` via dotenv) with `config.json` (business info). Returns the full config hash for all callers.
- **`save_config`** — always strips `client_id`/`client_secret` before writing so they can never land in `config.json`.
- **Migration** — if `config.json` contains `client_id`/`client_secret` from an older install, `load_dotenv` moves them to `<data_dir>/.env` and strips them from `config.json` silently on every startup.

### Dry-Run Mode

All commands support `--dry-run` (global class option). When set:

- Auth is partially bypassed — `valid_access_token` returns the stored access token if one exists and is not expired; falls back to `"dry-run-token"` when unauthenticated. `require_config` reads config.json directly without requiring credentials
- Most read API calls use cached data ignoring freshness (stale cache is acceptable); if cache is empty, reads return `[]`. Single-entry reads (`fetch_time_entry`) make a real API call using the available token, so `edit --dry-run` shows actual entry data when authenticated
- Write API calls (`create_time_entry`, `update_time_entry`, `delete_time_entry`) return mock responses without hitting the network
- A `[DRY RUN] No changes will be made.` banner is printed to stderr before the command runs
- With `--format json`, all output is wrapped with `"_dry_run": {"simulated": true}` metadata; array results are nested under `"data"`

Implementation uses `Thread.current[:fb_dry_run]` set in `invoke_command` with `ensure` cleanup (intentionally unchanged internal detail — not tied to the module namespace). Dry-run guards are added as the first line of ~8 leaf methods in `FreshBooks::CLI::Auth` and `FreshBooks::CLI::Api`. All business logic (name map building, pagination, caching) runs unchanged through the same code paths.

### JSON Output

All commands support `--format json` (global class option). Mutation commands (`log`, `edit`, `delete`) return the API response or structured confirmation. Read commands return data arrays or structured summaries.

## Testing Conventions

- **rspec-given** style: `Given`/`When`/`Then` blocks, not `describe`/`it`/`expect`
- Keep `rspec-given` syntax in place when editing specs. Do not convert any example, helper-driven case, or whole file to plain `it`/`expect` unless the user explicitly asks for a testing-style change.
- If a spec needs a different shape to make `rspec-given` work, keep the assertion inside `Given`/`When`/`Then` and adapt the helper or command invocation instead of rewriting the example as an RSpec `it`.
- For CLI abort paths in `spec/freshbooks/cli_spec.rb`, avoid changing the overall example style just to catch `SystemExit`. Prefer an isolated helper pattern or a lower-level test target that does not poison the suite exit status.
- `Failure(SystemExit)` for testing `abort` calls
- **webmock** stubs HTTP at the socket level — never stub HTTParty directly
- **File I/O** uses real files in a tmpdir (spec_helper sets `FreshBooks::CLI::Auth.data_dir = tmpdir` before each test and resets it with `FreshBooks::CLI::Auth.data_dir = nil` after — using the public setter, not `instance_variable_set`)
- **Spinner** is stubbed globally in `spec_helper` to just yield (no threads in tests)
- **$stdin** stubbed with `allow($stdin).to receive(:gets).and_return(...)` or `allow($stdin).to receive(:tty?).and_return(false)` for non-interactive tests

## Key Patterns

- All modules use `class << self` (singleton methods only, no instances)
- Config, tokens, defaults, cache are all separate JSON files under `FreshBooks::CLI::Auth.data_dir`
- `FreshBooks::CLI::Auth.data_dir=` is the seam for test isolation — point it at a tmpdir; set to `nil` to reset to auto-resolution. Resolution order: `FRESHBOOKS_HOME` env var → `~/.fb` (legacy) → platform-native default (macOS: `~/Library/Application Support/freshbooks`; Linux: `~/.config/freshbooks`)
- Docker wrapper (`./fb`) runs CLI in container with the data directory bind-mounted and host `TZ` passed through

## Branch & PR Naming

- **When starting new work based on a GitHub issue, always create a new branch before making any changes.**
- **Branches:** `{issue-number}-{issue-title}` (GitHub default convention, title converted to lowercase with hyphens). Example: `4-secure-credential-input`
- **PR titles:** `type(scope): description` (Conventional Commits style). Example: `feat(auth): add env var credential input`

## Planning & Issue Tracking

- Design specs and implementation plans go in `docs/plans/` — nowhere else.
- **Every plan must include these two bookend tasks — no exceptions:**
  - **Task 0 (first):** Post the full design spec to the related GitHub issue (not a link, not a summary — the full spec text). If no issue exists, create one first.
  - **Last task:** Update or create ALL related documentation: README, AGENTS.md, and any skill files (e.g. `skills/*/SKILL.md`) that reference changed behavior or conventions.
- These tasks must appear in the written plan and be executed like any other task.
- **AGENTS.md must be self-contained.** Never reference local or global config files (e.g. `~/.claude/CLAUDE.md`, `settings.json`) — those are not available to other developers or agents running in different environments. All guidance belongs in this file directly.
- **Answer simple commands directly.** When the user runs an informational command (`git branch`, `git status`, `git log`, etc.), output the result and stop. Do not add commentary, observations, or suggestions unless asked.
- **Never include real user data in issues or PRs.** FreshBooks client names, entry IDs, project names, and any live API data must be replaced with generic placeholders (e.g. `"My Client"`, `<entry-id>`) before posting.

## Skills

- **FreshBooks** (`skills/freshbooks/SKILL.md`) — Time tracking via the `fb` CLI. Auto-activates for time tracking queries.
- To install this repo's skill bundle into Codex, run:

```bash
npx skills add https://skills.sh/parasquid/freshbooks-cli/freshbooks
```

## Superpowers Overrides

- **Plans location:** Save all design specs and implementation plans to `docs/plans/` (overrides the skill default of `docs/superpowers/plans/`)

## FreshBooks API Gotchas

- **Services are project-scoped.** The global `/comments/business/{id}/services` endpoint often returns empty. Services are embedded in project JSON under the `services` array. Use `fb projects --format json` to see available services per project.
- **Dates must be full datetimes.** The API rejects bare dates like `"2026-03-04"` — use `"2026-03-04T00:00:00Z"`. The CLI's `normalize_datetime` helper handles this.
- **PUT replaces, not patches.** Updating a time entry replaces the entire record. The `edit` command sends all existing fields (client_id, project_id, service_id, duration, note, started_at, is_logged) alongside any changed fields to avoid wiping data.
