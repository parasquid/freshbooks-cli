# Dry-Run Mode Design

**Issue:** parasquid/freshbooks-cli#7
**Date:** 2026-03-27

## Summary

Add a global `--dry-run` flag that exercises the full CLI code path without making any external service calls. Auth is bypassed, read API calls use cached data (ignoring freshness), and write API calls return mock responses. The goal is a faithful simulation — the same code paths run, only the network leaf methods are swapped out.

## Scope

Applies to all commands. Mutation commands (`log`, `edit`, `delete`) gain the most — their writes are suppressed and mock responses are returned. Read commands (`entries`, `clients`, `projects`, `services`, `status`) still benefit from the auth bypass and stale-cache tolerance.

## Architecture

### Activation

`--dry-run` is a `class_option` on the Thor CLI, alongside the existing `--format` and `--no-interactive`. When set, two dry-run modules are prepended to their respective singleton classes inside `invoke_command`, before any command logic runs:

```ruby
Api.singleton_class.prepend(Api::DryRun)
Auth.singleton_class.prepend(Auth::DryRun)
```

### `Auth::DryRun`

Overrides only the two methods that touch external auth:

| Method | Dry-run behaviour |
|---|---|
| `valid_access_token` | Returns `"dry-run-token"` (no refresh attempt) |
| `require_config` | Calls `load_config`, fills missing `business_id`/`account_id` with `"0"` |

### `Api::DryRun`

Overrides only the leaf methods that touch the network. All business logic (`build_name_maps`, `fetch_projects_for_client`, pagination, cache writing) runs unchanged through the real `Api` code.

| Method | Dry-run behaviour |
|---|---|
| `headers` | Returns fake auth headers, bypassing `Auth.valid_access_token` |
| `config` | Calls `Auth.load_config` directly, bypassing `Auth.require_config` |
| `cached_data(key)` | Returns cache data ignoring the 10-minute freshness check (stale cache is acceptable) |
| `fetch_time_entries` | Returns `[]` (no cache for these) |
| `fetch_time_entry(id)` | Returns a minimal mock entry with the given ID |
| `create_time_entry(entry)` | Returns mock response with the payload echoed back |
| `update_time_entry(id, fields)` | Returns mock response with updated fields echoed back |
| `delete_time_entry(id)` | Returns `true` |

Read methods (`fetch_clients`, `fetch_projects`, `fetch_services`) are **not** overridden. Note that `fetch_time_entries` returning `[]` means `fb entries --dry-run` and `fb status --dry-run` will show empty/zero results — this is expected, since there are no cached time entries to draw from. They already check cache before hitting the network, so with a warm cache they return real data; with a stale/cold cache they return whatever is available (because `cached_data` now ignores freshness).

### File Layout

No new files. All changes are additive to existing files:

- `lib/fb/auth.rb` — `Auth::DryRun` module at the bottom
- `lib/fb/api.rb` — `Api::DryRun` module at the bottom
- `lib/fb/cli.rb` — `class_option :dry_run`, activation in `invoke_command`, banner output

## Output

### Table format

A `[DRY RUN] No changes will be made.` banner is printed to stderr before each command when `--dry-run` is set. All other output is identical to a normal run.

### JSON format (`--format json --dry-run`)

All JSON responses include a `_dry_run` metadata key:

```json
{
  "_dry_run": {
    "simulated": true,
    "payload_sent": { ... }
  },
  "result": { "time_entry": { ... } }
}
```

For read commands the `_dry_run` key is present but `payload_sent` is omitted (no payload).

## Mock Response Shape

### `create_time_entry`

```json
{
  "_dry_run": { "simulated": true, "payload_sent": { <entry fields> } },
  "result": { "time_entry": { <entry fields>, "id": 0 } }
}
```

### `update_time_entry`

```json
{
  "_dry_run": { "simulated": true, "payload_sent": { <fields> } },
  "result": { "time_entry": { <fields>, "id": <entry_id> } }
}
```

### `delete_time_entry`

Returns `true` (same as the real method).

### `fetch_time_entry`

```json
{
  "id": <entry_id>,
  "duration": 3600,
  "note": "(dry run - entry <entry_id>)",
  "started_at": "<today>T00:00:00Z",
  "is_logged": true
}
```

## Testing

All tests follow the existing rspec-given style. `Auth.data_dir` is pointed at a tmpdir for isolation. Webmock is active — any unexpected HTTP call will fail the test, serving as proof that dry-run made no network calls.

**Warm cache:** Pre-populate the tmpdir cache, run a command with `--dry-run`, assert no HTTP calls and `[DRY RUN]` in stderr.

**Cold/stale cache:** Empty or stale tmpdir, run with `--dry-run`, assert reads return empty/fixture data and no HTTP calls are made.

**Mutation commands:** Assert mock responses are returned with the `_dry_run` key, and no HTTP calls are made.

**JSON output:** Assert `_dry_run` metadata key present in all JSON responses under `--dry-run`.
