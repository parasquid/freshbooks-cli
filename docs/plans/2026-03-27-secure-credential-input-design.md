# Secure Credential Input for `fb auth setup`

**Issue:** #4 — fb auth setup should support secure credential input methods
**Date:** 2026-03-27

## Problem

The `fb auth setup` command requires OAuth credentials as CLI flags (`--client-id`, `--client-secret`). This exposes secrets in shell history and process listings (`ps aux`), flagged as a high-severity finding (W007) by Snyk.

## Design

### Approach: Targeted changes (env vars + masked input)

Two independent improvements to the two existing credential input paths (interactive and non-interactive), plus removal of the insecure CLI flags.

### Changes

#### 1. Remove `--client-id` and `--client-secret` CLI flags

Remove the `method_option` declarations and flag handling from `cli.rb`. The `setup_config_from_args` method will no longer accept arguments — it reads exclusively from environment.

#### 2. Environment variable support (non-interactive path)

`setup_config_from_args` reads credentials from environment variables:

- `FRESHBOOKS_CLIENT_ID`
- `FRESHBOOKS_CLIENT_SECRET`

These can be set via shell `export` or via a `.env` file (see below).

Error messages guide users to set env vars or use a `.env` file when credentials are missing.

#### 3. `.env` file loading via `dotenv` gem

Add `dotenv` as a runtime dependency. Before reading env vars, load `.env` files from two locations (first found wins):

1. `~/.fb/.env` (alongside other FB config files — primary location for installed gem users)
2. `./.env` (current working directory — conventional dotenv location for developers)

Create a `.env.example` in the project root:

```
# Copy to ~/.fb/.env or ./.env and fill in your credentials
# Get these from https://my.freshbooks.com/#/developer
FRESHBOOKS_CLIENT_ID=your_client_id_here
FRESHBOOKS_CLIENT_SECRET=your_client_secret_here
```

Add `.env` to `.gitignore`.

#### 4. Masked secret input (interactive path)

In `setup_config` (interactive), use `IO.console.getpass` from Ruby's `io/console` stdlib to mask the client secret. Client ID remains visible (not sensitive).

```ruby
require "io/console"

print "Client Secret: "
client_secret = IO.console.getpass("")
```

#### 5. Update help text and documentation

- Update `fb auth` help text and error messages to reference env vars and `.env` file
- Update `fb help` detailed command info
- Update README with credential setup documentation covering both methods:
  - **Method 1: `.env` file** (recommended) — copy `.env.example` to `~/.fb/.env`, fill in values
  - **Method 2: Shell export** — `export FRESHBOOKS_CLIENT_ID=xxx`

### Credential resolution order (non-interactive)

1. Shell environment variables (includes any loaded by dotenv from `.env`)
2. Abort with message explaining both `.env` file and `export` options

### Files to change

| File | Change |
|------|--------|
| `fb.gemspec` | Add `dotenv` runtime dependency |
| `lib/fb/auth.rb` | Add `load_dotenv`, update `setup_config_from_args` (no args, read ENV), mask secret in `setup_config` |
| `lib/fb/cli.rb` | Remove `--client-id`/`--client-secret` flags, update help text and error messages |
| `.gitignore` | Add `.env` |
| `.env.example` | New file with template |
| `README.md` | Document both credential input methods |
| `spec/fb/auth_spec.rb` | Update tests: remove flag-based tests, add env var and `.env` file coverage |
| `spec/fb/cli_spec.rb` | Update tests for removed flags |

### Testing

- **Env var path:** Set `ENV["FRESHBOOKS_CLIENT_ID"]` and `ENV["FRESHBOOKS_CLIENT_SECRET"]` in test, call `setup_config_from_args`, verify config saved
- **`.env` file path:** Write a `.env` file to test tmpdir, verify dotenv loads it
- **Missing credentials:** Verify abort message mentions both env vars and `.env` file
- **Interactive masking:** Stub `IO.console` to return a test value
- **Existing tests:** Update to remove references to `--client-id`/`--client-secret` flags

---

## Amendment: Credential Storage Separation

**Date:** 2026-03-27

### Problem

After initial implementation, credentials (`client_id`, `client_secret`) are still written to `config.json` alongside `business_id` and `account_id`. This means secrets live in a plain JSON file rather than the `.env` file designed for them.

### Design

#### Storage split

- `~/.fb/.env` — `FRESHBOOKS_CLIENT_ID`, `FRESHBOOKS_CLIENT_SECRET` (credentials only, never in `config.json`)
- `~/.fb/config.json` — `business_id`, `account_id` only

#### Changes to `auth.rb`

**`load_dotenv`** — extended with a migration step: if `config.json` has `client_id`/`client_secret`, move them to `~/.fb/.env`, then strip from `config.json`. Migration rules for `.env`:
- File doesn't exist → create with both keys
- File exists, keys missing → append
- File exists, keys present → leave as-is (already migrated)

Migration is silent and automatic on every run.

**`load_config`** — merges ENV vars + `config.json`. Returns the same `{"client_id", "client_secret", "business_id", "account_id"}` hash — all callers remain unchanged.

**`save_config`** — strips `client_id`/`client_secret` before writing, so credentials can never accidentally land in `config.json`.

**`setup_config_from_args`** — no longer writes to `config.json`. Returns the credentials hash in memory only for use during the OAuth flow.

**`setup_config` (interactive)** — writes credentials to `~/.fb/.env` instead of `config.json`:
- File doesn't exist → create with both keys
- File exists, keys missing → append
- File exists, keys present → ask user "Overwrite existing credentials? (y/n)", update only those two keys if yes

**Auth failure messaging** — when `refresh_token!` or `exchange_code` fails with an auth error, message tells the user to update credentials in `~/.fb/.env`.

#### Files to change

| File | Change |
|------|--------|
| `lib/fb/auth.rb` | Add `migrate_credentials_from_config`, `write_credentials_to_env`; update `load_dotenv`, `load_config`, `save_config`, `setup_config_from_args`, `setup_config`, auth failure messages |
| `spec/fb/auth_spec.rb` | Add migration tests, `.env` write tests, `load_config` merge tests |

#### Testing

- **Migration:** `config.json` with credentials → `load_dotenv` moves them to `.env`, strips from `config.json`
- **Migration append:** `.env` exists without keys → keys appended
- **Migration skip:** `.env` exists with keys → no change
- **`load_config` merge:** credentials in ENV, `business_id`/`account_id` in `config.json` → returns full hash
- **`save_config` strips credentials:** calling `save_config` with a hash containing credentials → `config.json` never contains them
- **Interactive setup writes `.env`:** `setup_config` → credentials in `~/.fb/.env`, not `config.json`
- **Overwrite prompt:** `setup_config` when `.env` already has keys → prompts user before overwriting
