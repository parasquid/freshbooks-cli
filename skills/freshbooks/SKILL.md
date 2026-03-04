---
name: freshbooks
description: Log time, check entries, and manage FreshBooks time tracking via the fb CLI
auto-activate: when the user asks about time tracking, logging hours, FreshBooks entries, work hours, or billing time
allowed-tools:
  - Bash(fb *)
  - Bash(./fb *)
---

# FreshBooks Time Tracking Skill

Manage FreshBooks time entries using the `fb` CLI tool.

## Prerequisites

Auth must be configured. Check with:

```bash
fb auth status --format json
```

If `config_exists` is false, guide the user through setup:
1. `fb auth setup --client-id ID --client-secret SECRET`
2. `fb auth url` — present URL to user
3. `fb auth callback "REDIRECT_URL"` — after user authorizes
4. If multiple businesses: `fb business --select ID`

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

**Important: Services are project-scoped.** `fb services` may return empty — services are embedded in project data. When logging time, use `--service "Name"` with the service name from the project (visible in `fb projects --format json` under the `services` array). Common service names: Development, Research, General, Meetings.

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
# --project, --service, --date are optional; --client, --duration, --note are required
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
1. `fb auth setup --client-id ID --client-secret SECRET --format json`
2. `fb auth url --format json` — show URL to user
3. User authorizes and provides redirect URL
4. `fb auth callback "REDIRECT_URL" --format json`
5. If response shows `business_selected: false`: `fb business --format json` then `fb business --select ID --format json`
