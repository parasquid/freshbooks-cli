# Dry-Run Follow-Up Fixes Design

**Date:** 2026-03-31
**Issues:** #9, #10, #11

## Background

The dry-run feature was implemented in v0.3.3. Three follow-up issues were filed after QA black-box testing.

---

## Issue #9 — `--dry-run` not listed in `fb help` output

**Problem:** `help_json` in `cli.rb` only lists `--no-interactive` and `--format json` in its `global_flags` hash. `--dry-run` is absent. Thor's auto-generated text help already shows it (from `class_option`), but the JSON help path does not.

**Fix:** Add `"--dry-run"` to the `global_flags` hash in `help_json` (`cli.rb:992`). No other changes needed.

---

## Issue #11 — `payload_sent` clobbered in JSON output

**Problem:** `invoke_command` wraps dry-run JSON output by merging `{ "_dry_run" => { "simulated" => true } }` into the captured output. However, `create_time_entry` and `update_time_entry` already return a `_dry_run` key containing `{ "simulated" => true, "payload_sent" => ... }`. The `data.merge(meta)` call overwrites the entire `_dry_run` key, discarding `payload_sent`.

**Fix:** In `invoke_command`, deep-merge the `_dry_run` key rather than overwriting it:

```ruby
existing = data["_dry_run"] || {}
wrapped = data.merge("_dry_run" => existing.merge("simulated" => true))
```

This preserves `payload_sent` (and any other keys the API layer adds) while guaranteeing `simulated: true` is present.

---

## Issue #10 — `edit --dry-run` shows stub data instead of actual entry fields

**Problem:** `fetch_time_entry` has a dry-run guard that returns a stub with no `client_id`, no `project_id`, a synthetic note, and today's date. The `edit` command uses this to build its pre-edit summary, so the user sees blank client, `-` project, and fake values instead of the actual entry's fields. The preview is misleading and unusable.

**Root cause:** The stub was added to allow dry-run to work without authentication. But for read-only calls like `fetch_time_entry`, real data is preferable when credentials are available.

**Fix — two changes:**

1. **`Auth.valid_access_token`** — in dry-run mode, attempt to load and return the real access token from config/cache first. Return it if a stored token exists; fall back to `"dry-run-token"` only if no token is available. This makes all read-only API calls work with real credentials when the user is already authenticated.

2. **`Api.fetch_time_entry`** — remove the dry-run stub entirely. With `valid_access_token` returning a real token when available, the real HTTP call proceeds normally. If the user is not authenticated, the call fails with a clear API error — consistent with any other unauthenticated command.

**Behaviour after fix:**

- Authenticated user running `edit --dry-run`: sees real entry data with proposed changes applied in the summary. No write is made.
- Unauthenticated user running `edit --dry-run`: fails at the fetch step with an API auth error (same as any unauthenticated command).

---

## Testing

Each fix has a corresponding spec change:

- **#9:** Add `"--dry-run"` assertion to `fb help --format json` spec.
- **#11:** Add assertion that `fb log --dry-run --format json` output contains `_dry_run.payload_sent`.
- **#10:** Update `edit --dry-run` spec to stub `fetch_time_entry` with realistic entry data (client_id, project_id, note, started_at) and assert the summary reflects those values.

---

## Files Changed

- `lib/fb/cli.rb` — `help_json` global_flags (#9), `invoke_command` dry-run merge (#11)
- `lib/fb/auth.rb` — `valid_access_token` dry-run fallback logic (#10)
- `lib/fb/api.rb` — remove `fetch_time_entry` dry-run stub (#10)
- `spec/fb/cli_spec.rb` — test coverage for #9 and #11
- `spec/fb/cli_spec.rb` — test coverage for #10 (edit dry-run section)
