# Dry-Run Follow-Up Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix three follow-up issues (#9, #10, #11) from the dry-run feature implementation.

**Architecture:** Three independent bug fixes: add `--dry-run` to the JSON help output, preserve `payload_sent` in the dry-run JSON wrapper, and make `edit --dry-run` fetch real entry data when authenticated.

**Tech Stack:** Ruby, Thor, HTTParty, RSpec, rspec-given, webmock

---

## File Map

| File | Change |
|------|--------|
| `lib/fb/cli.rb` | `help_json` global_flags (#9); `invoke_command` dry-run JSON merge (#11) |
| `lib/fb/auth.rb` | `valid_access_token` — return real token when available in dry-run (#10) |
| `lib/fb/api.rb` | Remove `fetch_time_entry` dry-run stub (#10) |
| `spec/fb/cli_spec.rb` | Tests for #9, #11, and updated `edit --dry-run` tests for #10 |
| `spec/fb/auth_spec.rb` | New test: `valid_access_token` returns real token in dry-run when tokens exist |
| `AGENTS.md` | Update dry-run section to reflect new auth and fetch behaviour |

---

## Task 1: Fix #9 — `--dry-run` missing from JSON help output

**Files:**
- Modify: `lib/fb/cli.rb:992-994`
- Modify: `spec/fb/cli_spec.rb` (after the `"help --format json includes new commands"` describe block)

- [ ] **Step 1: Write the failing test**

Add after the `"help --format json includes new commands"` describe block (around line 920 in `spec/fb/cli_spec.rb`):

```ruby
# --- dry-run flag in help --format json ---

describe "help --format json includes --dry-run in global_flags" do
  When(:output) {
    capture_stdout { FB::Cli.start(["help", "--format", "json"]) }
  }
  Then {
    json = JSON.parse(output)
    json["global_flags"].key?("--dry-run")
  }
end
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
docker compose run --rm --entrypoint rspec fb spec/fb/cli_spec.rb \
  --example "help --format json includes --dry-run"
```

Expected: FAIL — `expected true but got false` (key is absent).

- [ ] **Step 3: Add `--dry-run` to `help_json`**

In `lib/fb/cli.rb`, find the `help_json` method's `global_flags` hash (around line 992) and add the `--dry-run` entry:

```ruby
global_flags: {
  "--no-interactive" => "Disable interactive prompts (auto-detected when not a TTY)",
  "--format json"    => "Output format: json (available on all commands)",
  "--dry-run"        => "Simulate command without making network calls (writes skipped)"
},
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
docker compose run --rm --entrypoint rspec fb spec/fb/cli_spec.rb \
  --example "help --format json includes --dry-run"
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/fb/cli.rb spec/fb/cli_spec.rb
git commit -m "$(cat <<'EOF'
fix(help): add --dry-run to JSON help global_flags

Closes #9

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Fix #11 — `payload_sent` clobbered in dry-run JSON output

**Files:**
- Modify: `lib/fb/cli.rb:39-40` (inside `invoke_command`)
- Modify: `spec/fb/cli_spec.rb` (inside the `"log --dry-run"` describe block)

- [ ] **Step 1: Write the failing test**

In `spec/fb/cli_spec.rb`, inside `describe "log --dry-run"` (around line 959), add a new context after the existing `"json output includes _dry_run metadata"` context:

```ruby
context "json output includes _dry_run.payload_sent" do
  When(:stdout) {
    capture_stdout {
      FB::Cli.start(["log", "--client", "Acme Corp", "--duration", "1.5",
                     "--note", "test work", "--yes", "--dry-run", "--format", "json"])
    }
  }
  Then {
    json = JSON.parse(stdout)
    json["_dry_run"].key?("payload_sent")
  }
end
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
docker compose run --rm --entrypoint rspec fb spec/fb/cli_spec.rb \
  --example "payload_sent"
```

Expected: FAIL — `expected true but got false` (`payload_sent` key absent).

- [ ] **Step 3: Fix the merge in `invoke_command`**

In `lib/fb/cli.rb`, find these lines inside `invoke_command` (around line 38-41):

```ruby
data = JSON.parse(buffer.string)
meta = { "_dry_run" => { "simulated" => true } }
wrapped = data.is_a?(Array) ? meta.merge("data" => data) : data.merge(meta)
```

Replace with:

```ruby
data = JSON.parse(buffer.string)
existing_dry_run = data.is_a?(Hash) ? (data["_dry_run"] || {}) : {}
meta = { "_dry_run" => existing_dry_run.merge("simulated" => true) }
wrapped = data.is_a?(Array) ? { "_dry_run" => { "simulated" => true } }.merge("data" => data) : data.merge(meta)
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
docker compose run --rm --entrypoint rspec fb spec/fb/cli_spec.rb \
  --example "payload_sent"
```

Expected: PASS.

- [ ] **Step 5: Run full dry-run integration tests to check for regressions**

```bash
docker compose run --rm --entrypoint rspec fb spec/fb/cli_spec.rb \
  --example "dry-run"
```

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add lib/fb/cli.rb spec/fb/cli_spec.rb
git commit -m "$(cat <<'EOF'
fix(dry-run): preserve payload_sent when wrapping JSON output

invoke_command was overwriting the _dry_run key from the API layer,
discarding payload_sent. Deep-merge instead.

Closes #11

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Fix #10 — `edit --dry-run` shows real entry fields

**Files:**
- Modify: `lib/fb/auth.rb:278-279` (`valid_access_token`)
- Modify: `lib/fb/api.rb:167-176` (remove `fetch_time_entry` dry-run stub)
- Modify: `spec/fb/auth_spec.rb` (update and extend `valid_access_token in dry-run` tests)
- Modify: `spec/fb/cli_spec.rb` (update `edit --dry-run` describe block)

- [ ] **Step 1: Write the failing auth test**

In `spec/fb/auth_spec.rb`, rename the existing `".valid_access_token in dry-run"` describe to `"with no saved tokens"` and add a sibling context for when tokens exist. Replace the existing block (around line 474):

```ruby
describe ".valid_access_token in dry-run" do
  around do |example|
    Thread.current[:fb_dry_run] = true
    example.run
  ensure
    Thread.current[:fb_dry_run] = false
  end

  context "with no saved tokens" do
    When(:result) { FB::Auth.valid_access_token }
    Then { result == "dry-run-token" }
  end

  context "with a valid saved token" do
    Given {
      FB::Auth.save_tokens({
        "access_token" => "real-token-123",
        "refresh_token" => "refresh-abc",
        "expires_in" => 3600,
        "created_at" => Time.now.to_i
      })
    }
    When(:result) { FB::Auth.valid_access_token }
    Then { result == "real-token-123" }
  end
end
```

- [ ] **Step 2: Run the new auth test to verify it fails**

```bash
docker compose run --rm --entrypoint rspec fb spec/fb/auth_spec.rb \
  --example "valid_access_token in dry-run"
```

Expected: the `"with a valid saved token"` context FAILS — returns `"dry-run-token"` instead of `"real-token-123"`.

- [ ] **Step 3: Write the failing cli test for edit --dry-run**

In `spec/fb/cli_spec.rb`, replace the existing `describe "edit --dry-run"` block (around line 973) with:

```ruby
describe "edit --dry-run" do
  let(:fresh_cache) {
    {
      "updated_at" => Time.now.to_i,
      "clients_data" => [{ "id" => 10, "organization" => "Acme Corp", "fname" => "", "lname" => "" }],
      "projects_data" => [{ "id" => 20, "title" => "Website" }],
      "services_data" => [],
      "clients" => { "10" => "Acme Corp" },
      "projects" => { "20" => "Website" },
      "services" => {}
    }
  }
  let(:entry_url) { %r{api\.freshbooks\.com/timetracking/business/12345/time_entries/999} }

  before do
    FB::Auth.save_cache(fresh_cache)
    stub_request(:get, entry_url)
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          "result" => {
            "time_entry" => {
              "id" => 999, "duration" => 3600, "note" => "Old note",
              "started_at" => "2024-03-01T10:00:00Z",
              "client_id" => 10, "project_id" => 20, "is_logged" => true
            }
          }
        }.to_json
      )
  end

  context "table output shows real entry fields" do
    When(:stdout) {
      capture_stdout {
        FB::Cli.start(["edit", "--id", "999", "--duration", "2.0", "--yes", "--dry-run"])
      }
    }
    Then { stdout.include?("Acme Corp") }
    And  { stdout.include?("2.0h") }
  end

  context "json output includes _dry_run metadata" do
    When(:stdout) {
      capture_stdout {
        FB::Cli.start(["edit", "--id", "999", "--duration", "2.0",
                       "--yes", "--dry-run", "--format", "json"])
      }
    }
    Then {
      json = JSON.parse(stdout)
      json["_dry_run"]["simulated"] == true
    }
  end
end
```

- [ ] **Step 4: Run the cli test to verify it fails**

```bash
docker compose run --rm --entrypoint rspec fb spec/fb/cli_spec.rb \
  --example "edit --dry-run"
```

Expected: FAIL — `fetch_time_entry`'s dry-run stub returns no `client_id`, so the summary cannot resolve the client name. The `stdout.include?("Acme Corp")` assertion fails.

- [ ] **Step 5: Update `valid_access_token` in `lib/fb/auth.rb`**

Replace lines 278-279:

```ruby
def valid_access_token
  return "dry-run-token" if Thread.current[:fb_dry_run]
```

With:

```ruby
def valid_access_token
  if Thread.current[:fb_dry_run]
    tokens = load_tokens
    return tokens["access_token"] if tokens && !token_expired?(tokens)
    return "dry-run-token"
  end
```

- [ ] **Step 6: Remove the dry-run stub from `fetch_time_entry` in `lib/fb/api.rb`**

Remove lines 167-176 (the dry-run guard block):

```ruby
def fetch_time_entry(entry_id)
  if Thread.current[:fb_dry_run]
    return {
      "id" => entry_id,
      "duration" => 3600,
      "note" => "(dry run - entry #{entry_id})",
      "started_at" => "#{Date.today}T00:00:00Z",
      "is_logged" => true
    }
  end

  url = "#{BASE}/timetracking/business/#{business_id}/time_entries/#{entry_id}"
```

So the method becomes:

```ruby
def fetch_time_entry(entry_id)
  url = "#{BASE}/timetracking/business/#{business_id}/time_entries/#{entry_id}"
```

(Keep all lines after unchanged.)

- [ ] **Step 7: Run auth tests to verify they pass**

```bash
docker compose run --rm --entrypoint rspec fb spec/fb/auth_spec.rb \
  --example "valid_access_token in dry-run"
```

Expected: both contexts PASS.

- [ ] **Step 8: Run cli edit dry-run tests to verify they pass**

```bash
docker compose run --rm --entrypoint rspec fb spec/fb/cli_spec.rb \
  --example "edit --dry-run"
```

Expected: all PASS.

- [ ] **Step 9: Run full test suite to check for regressions**

```bash
docker compose run --rm --entrypoint rspec fb
```

Expected: all pass.

- [ ] **Step 10: Commit**

```bash
git add lib/fb/auth.rb lib/fb/api.rb spec/fb/auth_spec.rb spec/fb/cli_spec.rb
git commit -m "$(cat <<'EOF'
fix(dry-run): fetch real entry data in edit --dry-run when authenticated

valid_access_token now returns the stored token in dry-run mode when one
is available, falling back to "dry-run-token" only when unauthenticated.
fetch_time_entry's dry-run stub is removed so edit --dry-run shows the
actual entry fields rather than placeholder data.

Closes #10

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Update docs and close parent issue

**Files:**
- Modify: `AGENTS.md` (dry-run section)

- [ ] **Step 1: Update the dry-run section in `AGENTS.md`**

Find the `### Dry-Run Mode` section and update the first two bullets:

Replace:
```
- Auth is bypassed — `valid_access_token` returns `"dry-run-token"`, `require_config` reads config.json directly without requiring credentials
- Read API calls use cached data ignoring freshness (stale cache is acceptable); if cache is empty, reads return `[]`
```

With:
```
- Auth is partially bypassed — `valid_access_token` returns the stored access token if one exists and is not expired; falls back to `"dry-run-token"` when unauthenticated. `require_config` reads config.json directly without requiring credentials
- Most read API calls use cached data ignoring freshness (stale cache is acceptable); if cache is empty, reads return `[]`. Single-entry reads (`fetch_time_entry`) make a real API call using the available token, so `edit --dry-run` shows actual entry data when authenticated
```

- [ ] **Step 2: Commit and close parent issue**

```bash
git add AGENTS.md
git commit -m "$(cat <<'EOF'
docs(agents): update dry-run mode to reflect real-token and fetch behaviour

Closes #7

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```
