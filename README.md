# FreshBooks CLI (`fb`)

A command-line tool for managing FreshBooks time entries. Supports OAuth2 authentication, interactive time logging with remembered defaults, and monthly entry listings.

## Install

### Docker (no Ruby required)

```bash
git clone <repo-url> && cd freshbooks-cli
./fb auth
```

The `./fb` wrapper script runs the CLI inside a Docker container. Data persists in a named Docker volume.

### Ruby gem (native)

```bash
gem build fb.gemspec
gem install freshbooks-cli-*.gem
fb auth
```

Installs `fb` to your PATH — runs natively, no Docker involved. Data stored in `~/.fb/`.

## Setup

Running any command for the first time triggers setup:

1. Create a FreshBooks app at https://my.freshbooks.com/#/developer
2. Set the redirect URI to `https://localhost`
3. Enter your Client ID and Client Secret when prompted
4. Complete the OAuth flow — your `business_id` and `account_id` are auto-discovered

All data is stored in `~/.fb/` (tokens, config, defaults, cache).

## Commands

### `fb auth`

Authenticate with FreshBooks. Prints an authorization URL, waits for you to paste the redirect URL, then exchanges the code for tokens.

```
$ fb auth
Open this URL in your browser:

  https://auth.freshbooks.com/oauth/authorize?client_id=...

Paste the redirect URL: https://localhost?code=abc123

Authentication successful!
Business: Acme Inc
  business_id: 12345
  account_id: 67890
```

Tokens auto-refresh before every API call — no need to re-auth unless you revoke app access.

### `fb log`

Log a time entry. Interactive by default — walks you through selecting a client, project, service, date, duration, and note. Remembers your last selections as defaults.

```
$ fb log

Clients:

  1. Acme Corp [default]
  2. Globex Inc

Select client (1-2) [1]:

Projects:

  1. Website Redesign [default]

Select project (1-1, Enter to skip) [1]:

Date [2026-03-03]:
Duration (hours): 2.5
Note: Built API endpoints

--- Time Entry Summary ---
  Client:   Acme Corp
  Project:  Website Redesign
  Date:     2026-03-03
  Duration: 2.5h
  Note:     Built API endpoints
--------------------------

Submit? (Y/n):
Time entry created!
```

**Non-interactive mode** — pass flags to skip prompts:

```bash
fb log --client "Acme Corp" --project "Website Redesign" --duration 2.5 --note "Built API endpoints" --yes
```

### `fb entries`

List time entries for the current month.

```
$ fb entries
Date        Client      Project           Note                        Duration
----------  ----------  ----------------  --------------------------  --------
2026-03-01  Acme Corp   Website Redesign  Design review               1.5h
2026-03-03  Acme Corp   Website Redesign  Built API endpoints         2.5h

Total: 4.0h
```

Options:

```bash
fb entries --month 2 --year 2026    # Different month
fb entries --format json            # Machine-readable output
```

### `fb help`

```bash
fb help              # Human-readable help
fb help --format json  # Machine-readable JSON (for agents/scripts)
```

## Agent/script usage

The CLI is designed to be scriptable:

- `fb help --format json` — discover all commands and flags
- `fb log --client "..." --duration 2.5 --note "..." --yes` — fully non-interactive
- `fb entries --format json` — structured output
