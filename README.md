# FreshBooks CLI (`fb`)

A command-line tool for managing FreshBooks time tracking. Supports OAuth2 authentication, interactive time logging with remembered defaults, entry listings, client/project/service browsing, hours summaries, and inline editing and deletion of entries.

<img width="1093" height="454" alt="freshbooks-cli-screenshot" src="docs/images/screenshot.png" />

## Install

### Docker (no Ruby required)

```bash
git clone <repo-url> && cd freshbooks-cli
./fb auth
```

The `./fb` wrapper script runs the CLI inside a Docker container. Data persists in `.fb/` in the project directory.

### RubyGems

```bash
gem install freshbooks-cli
fb auth
```

### Ruby gem (from source)

```bash
gem build fb.gemspec
gem install freshbooks-cli-*.gem
fb auth
```

Both install `fb` to your PATH — runs natively, no Docker involved. Data stored in `~/.fb/`.

## Setup

Running any command for the first time triggers setup:

1. Create a FreshBooks app at https://my.freshbooks.com/#/developer
2. Set the redirect URI to `https://localhost`
3. Enable these scopes:
   - `user:profile:read` — discover business/account IDs (enabled by default)
   - `user:clients:read` — list clients for selection
   - `user:projects:read` — list projects for selection
   - `user:billable_items:read` — list services for selection
   - `user:time_entries:read` — list time entries
   - `user:time_entries:write` — create time entries
4. Enter your Client ID and Client Secret when prompted
5. Complete the OAuth flow — your `business_id` and `account_id` are auto-discovered

All data is stored in `~/.fb/` (or `.fb/` in the project directory when using Docker).

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

Tokens auto-refresh before every API call — no need to re-auth unless you revoke app access. If you run any command without being authenticated, the auth flow starts automatically.

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

List time entries. Defaults to the current month.

```
$ fb entries
✓ Fetching time entries (2026-03-01 to 2026-03-31)
✓ Resolving names
ID      Date        Client      Project           Note                 Duration
------  ----------  ----------  ----------------  -------------------  --------
12345   2026-03-01  Acme Corp   Website Redesign  Design review        1.5h
12346   2026-03-03  Acme Corp   Website Redesign  Built API endpoints  2.5h

Total: 4.0h
```

Date filtering:

```bash
fb entries                              # Current month (default)
fb entries --from 2026-01-01            # Jan 1 onwards
fb entries --to 2026-02-28             # Everything up to Feb 28
fb entries --from 2026-01-01 --to 2026-01-31  # Specific range
fb entries --month 2 --year 2026       # Shorthand for a whole month
fb entries --format json               # Machine-readable output
```

### `fb clients`

List all clients on your FreshBooks account.

```
$ fb clients
✓ Fetching clients
Name        Email             Organization
----------  ----------------  ------------
Acme Corp   joe@acme.com      Acme Corp
Jane Doe    jane@example.com  -
```

```bash
fb clients --format json    # Machine-readable output
```

### `fb projects`

List all projects. Optionally filter by client.

```
$ fb projects
✓ Resolving names
✓ Fetching projects
Title             Client      Status
----------------  ----------  ------
Website Redesign  Acme Corp   active
Mobile App        Acme Corp   active
```

```bash
fb projects --client "Acme Corp"   # Filter by client name
fb projects --format json          # Machine-readable output
```

### `fb services`

List all services.

```
$ fb services
✓ Fetching services
Name          Billable
------------  --------
Development   yes
Design        yes
Meetings      no
```

```bash
fb services --format json   # Machine-readable output
```

### `fb status`

Show an hours summary for today, this week, and this month — grouped by client and project.

```
$ fb status
✓ Fetching time entries
✓ Resolving names

Today (2026-03-04)
  Acme Corp / Website Redesign: 2.5h
  Total: 2.5h

This Week (2026-03-03 to 2026-03-04)
  Acme Corp / Website Redesign: 6.0h
  Total: 6.0h

This Month (2026-03-01 to 2026-03-04)
  Acme Corp / Website Redesign: 12.0h
  Globex Inc / Mobile App: 4.0h
  Total: 16.0h
```

### `fb delete`

Delete a time entry. Interactive by default — shows today's entries for selection. Use `--id` to skip the picker.

```bash
fb delete                  # Interactive — pick from today's entries
fb delete --id 12345       # Delete specific entry (prompts for confirmation)
fb delete --id 12345 --yes # Skip confirmation
```

### `fb edit`

Edit a time entry. Fetches the entry, shows current values as defaults, and lets you change any field. Use flags for non-interactive/scripted usage.

```bash
fb edit                              # Interactive — pick entry, edit fields
fb edit --id 12345                   # Edit specific entry interactively
fb edit --id 12345 --duration 1.5 --yes  # Scripted — update duration, skip confirmation
fb edit --id 12345 --note "Updated note" --date 2026-03-01 --yes
fb edit --id 12345 --client "Globex Inc" --project "Mobile App" --yes
```

### `fb cache`

Manage the local data cache. Clients, projects, and services are cached for 10 minutes to speed up commands.

```bash
fb cache              # Show cache status (default)
fb cache status       # Same — show age and item counts
fb cache refresh      # Force-refresh all cached data
fb cache clear        # Delete the cache file
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
- `fb entries --format json` — structured output (includes entry IDs)
- `fb clients --format json` / `fb projects --format json` / `fb services --format json` — list resources
- `fb edit --id <ID> --duration 1.5 --yes` — edit without prompts
- `fb delete --id <ID> --yes` — delete without prompts
- `fb status` — quick hours overview
- `fb cache refresh` — pre-warm the cache
