---
name: freshbooks
description: 'Log time, check entries, edit/delete entries, and troubleshoot FreshBooks auth using the fb CLI. Use this skill whenever the request is about FreshBooks time tracking workflows: timesheets, billable hours, work logs, correcting logged time, reconciling daily/weekly totals, or auth/business selection needed to perform those tasks, even if the user does not explicitly ask for "FreshBooks CLI". Do not use this skill for unrelated FreshBooks tasks such as invoice design, accounting reports, or general bookkeeping that does not involve time entries.'
auto-activate: when the user asks to log/edit/delete/check FreshBooks time entries, reconcile billable hours, fix timesheet mistakes, or complete auth/business selection required for those time-entry actions; do not auto-activate for invoices, expense bookkeeping, payment failures, branding, or accounting reports unless time-entry operations are also explicitly requested
allowed-tools:
  - Bash(fb *)
  - Bash(./fb *)
---

# FreshBooks Time Tracking Skill

Manage FreshBooks time entries using the `fb` CLI tool.

## Prerequisites

Always run this preflight before any time logging or entry mutation:

```bash
command -v fb >/dev/null 2>&1
fb auth status --format json
fb cache status --format json
```

If `fb` is missing:
- Stop and tell the user to install the FreshBooks CLI binary first.
- Do not continue with auth or logging commands until `fb` is available.

If both `fb` and `./fb` are available:
- Prefer `./fb` when working inside this repository to preserve project-local behavior.
- Otherwise use `fb`.

## Deterministic Auth State Machine (Minimize Back-and-Forth)

Use `fb auth status --format json` and branch exactly once per blocker:

1. If `config_exists` is `false`:
   - Ask once for both values in one message: `client_id` and `client_secret`
   - Tell the user to set env vars or save to `~/.fb/.env`, then run `fb auth setup --format json`:
     - Option A (env vars): `FRESHBOOKS_CLIENT_ID=ID FRESHBOOKS_CLIENT_SECRET=SECRET fb auth setup --format json`
     - Option B (.env file): save to `~/.fb/.env`, then `fb auth setup --format json`
   - Run: `fb auth url --format json`
   - Provide auth URL and request one value only: full redirect URL (`https://localhost/?code=...`)

2. If `config_exists` is `true` and `tokens_exist` is `false`:
   - Run: `fb auth url --format json`
   - Ask only for full redirect URL

3. After redirect URL is provided:
   - Run: `fb auth callback "REDIRECT_URL" --format json`
   - If response contains `"business_selected": false`:
     - Ask only for business ID, then run `fb business --select ID --format json`

4. If `tokens_exist` is `true` but `business_id` is null:
   - Run: `fb business --format json`
   - Ask only for business ID, then run `fb business --select ID --format json`

5. After auth completion:
   - Re-run: `fb auth status --format json`
   - Proceed only when `config_exists=true`, `tokens_exist=true`, and `business_id` is set.

## Question Minimization Rules

- Ask at most one targeted question per true blocker.
- Never ask permission questions (e.g. "should I proceed?").
- Never ask for values that can be derived from API data.
- Batch credential asks together when setup is missing (`client_id` + `client_secret`); instruct the user to set `FRESHBOOKS_CLIENT_ID`/`FRESHBOOKS_CLIENT_SECRET` env vars or save to `~/.fb/.env`.
- For OAuth completion, ask only for the full callback URL.
- For business selection, ask only for the business ID.
- If a command fails, show the concrete error and ask only for the single missing input needed to continue.

## Client/Project/Service Resolution Rules

- Before logging, resolve resources in this order:
  1. `fb clients --format json`
  2. `fb projects --client "Name" --format json`
- Services are project-scoped. Always resolve service from the selected project's `services` array.
- Never depend on `fb services` alone for logging decisions.
- If multiple clients exist and user did not specify one, ask once for client name.
- If project is ambiguous, ask once for project name.
- If service cannot be inferred from user intent, ask once for service name.

## Dynamic Context

Current auth and cache state:

```
!fb auth status 2>&1
```

```
!fb cache status --format json 2>&1
```

## Agent Rules

When executing `fb` commands:
- **Always** use `--format json` for parseable output
- **Always** use `--yes` to skip confirmation prompts on mutations
- **Always** pass explicit flags (`--client`, `--duration`, `--note`, `--id`) — never rely on interactive prompts
- **Always** use `--id` for `edit` and `delete` commands
- Parse JSON output to extract entry IDs, totals, and status
- After each mutation (`log`, `edit`, `delete`), run one verification read (`fb entries ... --format json` or `fb status --format json`) and report the result.

**Important: Services are project-scoped and MUST always be specified when logging time.** `fb services` may return empty — services are embedded in project data. Use `--service "Name"` with the service name from the project (visible in `fb projects --format json` under the `services` array). Common service names: Development, Research, General, Meetings. Infer the service from context clues in the user's request (e.g. "development work" → "Development", "a meeting" → "Meetings"). If the service cannot be inferred, ask the user before logging.

## Command Reference

### Check Status
```bash
fb status --format json              # Hours summary (today/week/month)
fb entries --format json             # Current month entries
fb entries --from YYYY-MM-DD --to YYYY-MM-DD --format json  # Date range
```

### Log Time
```bash
fb log --client "Client Name" --project "Project" --service "Service" --duration HOURS --note "Description" --yes --format json
# --project is required when multiple projects are possible and should be supplied for deterministic automation.
# --date is optional; --client, --duration, --note, and --service are required.
# IMPORTANT: Always include --service. Infer the service from context (e.g. "development work" → "Development",
# "meeting" → "Meetings", "research" → "Research"). If unsure, ask the user. Never omit --service.
```

### Edit Entry
```bash
fb edit --id ENTRY_ID --duration HOURS --yes --format json
fb edit --id ENTRY_ID --note "New note" --yes --format json
fb edit --id ENTRY_ID --service "Meetings" --yes --format json
# Edit preserves all existing fields — only specified flags are changed
```

### Delete Entry
```bash
fb delete --id ENTRY_ID --yes --format json
```

### List Resources
```bash
fb clients --format json
fb projects --format json                   # Includes project-scoped services in response
fb projects --client "Name" --format json   # Filter by client; services array shows available services
fb business --format json
```

### Cache Management
```bash
fb cache status --format json   # Check cache freshness
fb cache refresh                # Force refresh
```

## Workflows

### Log multiple entries for one date (batch mode)
1. Ensure auth is valid via the auth state machine above.
2. Resolve client/project/services once:
   - `fb clients --format json`
   - `fb projects --client "Name" --format json`
3. Execute all `fb log` commands in sequence (same date) with explicit flags:
   - `--client`, `--project`, `--service`, `--date`, `--duration`, `--note`, `--yes`, `--format json`
4. Verify in one command:
   - `fb entries --from YYYY-MM-DD --to YYYY-MM-DD --format json`
5. Return:
   - created entry IDs
   - per-entry duration and note
   - total hours for the date

### Recovery flow for common failures
- `No config found`:
  - Run auth state machine step 1.
- `Could not find 'code' parameter`:
  - Ask user to paste full redirect URL including query string.
- `Multiple clients found. Use --client`:
  - Ask once for client name, then continue.
- `Multiple projects found. Use --project`:
  - Ask once for project name, then continue.
- `Service not found`:
  - Refresh project list for selected client and pick service from that project.
- Missing required flags in non-interactive mode:
  - Re-run command with explicit required flags; do not switch to interactive prompts.

## Response Contract

When reporting results to the user:
- Include what command(s) were run.
- Include key IDs and totals (entry ID, duration, date range, total hours).
- If verification fails, state exactly what failed and the next corrective action.
- Keep output concise and machine-checkable when possible (prefer JSON-derived facts, not guesses).

### Log hours for today
1. `fb clients --format json` — get available clients
2. `fb projects --client "Name" --format json` — get projects and their services
3. `fb log --client "Name" --project "Project" --service "Service" --duration 2.5 --note "Work description" --yes --format json`

### Check how many hours logged today
```bash
fb status --format json
```
Parse `today.total_hours` from the response.

### Edit the most recent entry
1. `fb entries --from TODAY --to TODAY --format json` — get today's entries
2. Find the entry to edit, get its `id`
3. `fb edit --id ID --duration 3 --yes --format json`

### Full auth setup (new user)
1. Ask user for `client_id` and `client_secret`, then: `FRESHBOOKS_CLIENT_ID=ID FRESHBOOKS_CLIENT_SECRET=SECRET fb auth setup --format json`
2. `fb auth url --format json` — show URL to user
3. User authorizes and provides full redirect URL (`https://localhost/?code=...`)
4. `fb auth callback "REDIRECT_URL" --format json`
5. If response shows `business_selected: false`: `fb business --format json` then `fb business --select ID --format json`
