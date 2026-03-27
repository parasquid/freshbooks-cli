# Dry-Run Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a global `--dry-run` flag that exercises the full CLI code path without making any external network calls, using cached data for reads and mock responses for writes.

**Architecture:** A thread-local flag (`Thread.current[:fb_dry_run]`) is set in `invoke_command` when `--dry-run` is passed and cleared in `ensure`. Dry-run branches are added to ~9 leaf methods in `Auth` and `Api` that touch the network; all business logic (name map building, pagination, caching) runs unchanged through the same code paths.

**Tech Stack:** Ruby, Thor, RSpec-Given, WebMock (webmock's `disable_net_connect!` serves as proof that no HTTP calls were made — any unexpected call raises an error)

---

### Task 1: Add `--dry-run` class option, thread-local activation, and stderr banner

**Files:**
- Modify: `lib/fb/cli.rb`
- Modify: `spec/fb/cli_spec.rb`

- [ ] **Step 1: Write the failing test**

Add a `capture_stderr` helper at the bottom of `spec/fb/cli_spec.rb` (after `capture_stdout`), then add this test block inside `RSpec.describe FB::Cli`:

```ruby
# --- dry-run banner ---

describe "--dry-run banner" do
  When(:stderr_output) {
    capture_stderr { capture_stdout { FB::Cli.start(["version", "--dry-run"]) } }
  }
  Then { stderr_output.include?("[DRY RUN]") }
end
```

And the helper at the bottom of the file (after the existing `capture_stdout` def):

```ruby
def capture_stderr
  original = $stderr
  $stderr = StringIO.new
  yield
  $stderr.string
ensure
  $stderr = original
end
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
docker compose run --rm --entrypoint rspec fb spec/fb/cli_spec.rb -e "dry-run banner"
```

Expected: FAIL — `unknown option '--dry-run'` or similar

- [ ] **Step 3: Add `class_option :dry_run` and update `invoke_command` in `lib/fb/cli.rb`**

Add `require "stringio"` after the existing requires at the top of the file.

Add the new class option after the existing class options (after line 16):

```ruby
class_option :dry_run, type: :boolean, default: false, desc: "Simulate command without making network calls"
```

Replace the existing `invoke_command` block:

```ruby
no_commands do
  def invoke_command(command, *args)
    Spinner.interactive = interactive?
    return super unless options[:dry_run]

    Thread.current[:fb_dry_run] = true
    $stderr.puts "[DRY RUN] No changes will be made."

    if options[:format] == "json"
      original_stdout = $stdout
      buffer = StringIO.new
      $stdout = buffer
      begin
        super
      ensure
        $stdout = original_stdout
      end
      begin
        data = JSON.parse(buffer.string)
        meta = { "_dry_run" => { "simulated" => true } }
        wrapped = data.is_a?(Array) ? meta.merge("data" => data) : data.merge(meta)
        puts JSON.pretty_generate(wrapped)
      rescue JSON::ParserError
        print buffer.string
      end
    else
      super
    end
  ensure
    Thread.current[:fb_dry_run] = false
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
docker compose run --rm --entrypoint rspec fb spec/fb/cli_spec.rb -e "dry-run banner"
```

Expected: PASS

- [ ] **Step 5: Run the full test suite to verify no regressions**

```bash
docker compose run --rm --entrypoint rspec fb
```

Expected: all existing tests pass

- [ ] **Step 6: Commit**

```bash
git add lib/fb/cli.rb spec/fb/cli_spec.rb
git commit -m "feat(cli): add --dry-run class option with banner and thread-local activation"
```

---

### Task 2: Add dry-run branches to `Auth`

**Files:**
- Modify: `lib/fb/auth.rb`
- Modify: `spec/fb/auth_spec.rb`

- [ ] **Step 1: Write failing tests**

Add to `spec/fb/auth_spec.rb` inside `RSpec.describe FB::Auth`:

```ruby
# --- Dry-run mode ---

describe ".valid_access_token in dry-run" do
  around do |example|
    Thread.current[:fb_dry_run] = true
    example.run
  ensure
    Thread.current[:fb_dry_run] = false
  end

  When(:result) { FB::Auth.valid_access_token }
  Then { result == "dry-run-token" }
end

describe ".require_config in dry-run with existing config" do
  around do |example|
    Thread.current[:fb_dry_run] = true
    example.run
  ensure
    Thread.current[:fb_dry_run] = false
  end

  Given {
    FB::Auth.save_config("business_id" => 99, "account_id" => "acc1")
  }
  When(:result) { FB::Auth.require_config }
  Then { result["business_id"] == 99 }
  And  { result["account_id"] == "acc1" }
end

describe ".require_config in dry-run with no config" do
  around do |example|
    Thread.current[:fb_dry_run] = true
    example.run
  ensure
    Thread.current[:fb_dry_run] = false
  end

  When(:result) { FB::Auth.require_config }
  Then { result["business_id"] == "0" }
  And  { result["account_id"] == "0" }
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
docker compose run --rm --entrypoint rspec fb spec/fb/auth_spec.rb -e "dry-run"
```

Expected: FAIL — methods behave normally instead of returning dry-run values

- [ ] **Step 3: Add dry-run branches to `lib/fb/auth.rb`**

In `valid_access_token`, add the guard as the very first line of the method body:

```ruby
def valid_access_token
  return "dry-run-token" if Thread.current[:fb_dry_run]
  # ... rest of existing implementation unchanged
```

In `require_config`, add the guard as the very first line of the method body:

```ruby
def require_config
  if Thread.current[:fb_dry_run]
    config = load_config || {}
    config["business_id"] ||= "0"
    config["account_id"] ||= "0"
    return config
  end
  # ... rest of existing implementation unchanged
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
docker compose run --rm --entrypoint rspec fb spec/fb/auth_spec.rb -e "dry-run"
```

Expected: PASS

- [ ] **Step 5: Run the full test suite**

```bash
docker compose run --rm --entrypoint rspec fb
```

Expected: all tests pass

- [ ] **Step 6: Commit**

```bash
git add lib/fb/auth.rb spec/fb/auth_spec.rb
git commit -m "feat(auth): add dry-run branches to valid_access_token and require_config"
```

---

### Task 3: Add dry-run branches to `Api` — read path

This covers `cached_data` (ignore freshness), `fetch_all_pages` (return `[]`), `fetch_services` (direct HTTParty call bypassed), and `fetch_time_entry` (mock entry).

**Files:**
- Modify: `lib/fb/api.rb`
- Modify: `spec/fb/api_spec.rb`

- [ ] **Step 1: Write failing tests**

Add to `spec/fb/api_spec.rb` inside `RSpec.describe FB::Api`. All dry-run tests use an `around` block to set/clear the thread-local:

```ruby
# --- Dry-run read path ---

describe "dry-run read path" do
  around do |example|
    Thread.current[:fb_dry_run] = true
    example.run
  ensure
    Thread.current[:fb_dry_run] = false
  end

  describe ".cached_data ignores freshness in dry-run" do
    Given {
      stale_cache = {
        "updated_at" => Time.now.to_i - 700,  # 700s ago, past the 600s threshold
        "clients_data" => [{ "id" => 1, "organization" => "Acme" }]
      }
      FB::Auth.save_cache(stale_cache)
    }
    When(:result) { FB::Api.cached_data("clients_data") }
    Then { result == [{ "id" => 1, "organization" => "Acme" }] }
  end

  describe ".fetch_all_pages returns empty array in dry-run" do
    When(:result) {
      FB::Api.fetch_all_pages("https://api.freshbooks.com/fake", "items")
    }
    Then { result == [] }
  end

  describe ".fetch_services returns empty array in dry-run (no HTTP)" do
    # No webmock stubs — any HTTP call would raise WebMock::NetConnectNotAllowedError
    When(:result) { FB::Api.fetch_services }
    Then { result == [] }
  end

  describe ".fetch_services uses stale cache in dry-run" do
    Given {
      stale_cache = {
        "updated_at" => Time.now.to_i - 700,
        "services_data" => [{ "id" => 5, "name" => "Dev" }]
      }
      FB::Auth.save_cache(stale_cache)
    }
    When(:result) { FB::Api.fetch_services }
    Then { result == [{ "id" => 5, "name" => "Dev" }] }
  end

  describe ".fetch_time_entry returns mock entry in dry-run" do
    When(:result) { FB::Api.fetch_time_entry(42) }
    Then { result["id"] == 42 }
    And  { result["duration"] == 3600 }
    And  { result["is_logged"] == true }
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
docker compose run --rm --entrypoint rspec fb spec/fb/api_spec.rb -e "dry-run read path"
```

Expected: FAIL — methods hit network or return real values

- [ ] **Step 3: Add dry-run branches to read methods in `lib/fb/api.rb`**

In `cached_data`, add guard as first line:

```ruby
def cached_data(key)
  return Auth.load_cache[key] if Thread.current[:fb_dry_run]
  cache = Auth.load_cache
  return nil unless cache["updated_at"] && (Time.now.to_i - cache["updated_at"]) < 600
  cache[key]
end
```

In `fetch_all_pages`, add guard as first line of method body:

```ruby
def fetch_all_pages(url, result_key, params: {})
  return [] if Thread.current[:fb_dry_run]
  # ... rest of existing implementation unchanged
```

In `fetch_services`, add guard as first line of method body:

```ruby
def fetch_services(force: false)
  return (Auth.load_cache["services_data"] || []) if Thread.current[:fb_dry_run]
  # ... rest of existing implementation unchanged
```

In `fetch_time_entry`, add guard as first line of method body:

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
  # ... rest of existing implementation unchanged
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
docker compose run --rm --entrypoint rspec fb spec/fb/api_spec.rb -e "dry-run read path"
```

Expected: PASS

- [ ] **Step 5: Run the full test suite**

```bash
docker compose run --rm --entrypoint rspec fb
```

Expected: all tests pass

- [ ] **Step 6: Commit**

```bash
git add lib/fb/api.rb spec/fb/api_spec.rb
git commit -m "feat(api): add dry-run branches to read leaf methods"
```

---

### Task 4: Add dry-run branches to `Api` — write path

**Files:**
- Modify: `lib/fb/api.rb`
- Modify: `spec/fb/api_spec.rb`

- [ ] **Step 1: Write failing tests**

Add to the `"dry-run read path"` describe block in `spec/fb/api_spec.rb` (rename outer block to `"dry-run"` to cover both read and write, or add a new block — either works):

```ruby
describe "dry-run write path" do
  around do |example|
    Thread.current[:fb_dry_run] = true
    example.run
  ensure
    Thread.current[:fb_dry_run] = false
  end

  describe ".create_time_entry returns mock response in dry-run" do
    let(:entry) { { "duration" => 3600, "note" => "test", "client_id" => 10 } }
    When(:result) { FB::Api.create_time_entry(entry) }
    Then { result["_dry_run"]["simulated"] == true }
    And  { result["_dry_run"]["payload_sent"] == entry }
    And  { result["result"]["time_entry"]["id"] == 0 }
    And  { result["result"]["time_entry"]["duration"] == 3600 }
  end

  describe ".update_time_entry returns mock response in dry-run" do
    let(:fields) { { "duration" => 5400, "note" => "updated" } }
    When(:result) { FB::Api.update_time_entry(99, fields) }
    Then { result["_dry_run"]["simulated"] == true }
    And  { result["_dry_run"]["payload_sent"] == fields }
    And  { result["result"]["time_entry"]["id"] == 99 }
    And  { result["result"]["time_entry"]["duration"] == 5400 }
  end

  describe ".delete_time_entry returns true in dry-run" do
    When(:result) { FB::Api.delete_time_entry(99) }
    Then { result == true }
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
docker compose run --rm --entrypoint rspec fb spec/fb/api_spec.rb -e "dry-run write path"
```

Expected: FAIL — methods attempt HTTP calls (WebMock raises) or return wrong values

- [ ] **Step 3: Add dry-run branches to write methods in `lib/fb/api.rb`**

In `create_time_entry`, add guard as first lines:

```ruby
def create_time_entry(entry)
  if Thread.current[:fb_dry_run]
    return {
      "_dry_run" => { "simulated" => true, "payload_sent" => entry },
      "result" => { "time_entry" => entry.merge("id" => 0) }
    }
  end
  # ... rest of existing implementation unchanged
```

In `update_time_entry`, add guard as first lines:

```ruby
def update_time_entry(entry_id, fields)
  if Thread.current[:fb_dry_run]
    return {
      "_dry_run" => { "simulated" => true, "payload_sent" => fields },
      "result" => { "time_entry" => fields.merge("id" => entry_id) }
    }
  end
  # ... rest of existing implementation unchanged
```

In `delete_time_entry`, add guard as first line:

```ruby
def delete_time_entry(entry_id)
  return true if Thread.current[:fb_dry_run]
  # ... rest of existing implementation unchanged
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
docker compose run --rm --entrypoint rspec fb spec/fb/api_spec.rb -e "dry-run write path"
```

Expected: PASS

- [ ] **Step 5: Run the full test suite**

```bash
docker compose run --rm --entrypoint rspec fb
```

Expected: all tests pass

- [ ] **Step 6: Commit**

```bash
git add lib/fb/api.rb spec/fb/api_spec.rb
git commit -m "feat(api): add dry-run branches to write leaf methods"
```

---

### Task 5: End-to-end dry-run integration tests

These tests verify that complete CLI commands run successfully under `--dry-run` with no HTTP stubs. WebMock's global `disable_net_connect!` ensures any unexpected HTTP call fails the test.

**Files:**
- Modify: `spec/fb/cli_spec.rb`

- [ ] **Step 1: Write the tests**

Add a new `describe "dry-run integration"` block inside `RSpec.describe FB::Cli`. Tests use a stale cache (700 seconds old) so normal freshness checks would fail but dry-run's stale-cache-tolerance kicks in:

```ruby
# --- dry-run integration ---

describe "dry-run integration" do
  let(:stale_cache) {
    {
      "updated_at" => Time.now.to_i - 700,
      "clients_data" => [{ "id" => 10, "organization" => "Acme Corp", "fname" => "", "lname" => "" }],
      "projects_data" => [{ "id" => 20, "title" => "Website", "client_id" => 10, "services" => [] }],
      "services_data" => [{ "id" => 30, "name" => "Development" }],
      "clients" => { "10" => "Acme Corp" },
      "projects" => { "20" => "Website" },
      "services" => { "30" => "Development" }
    }
  }

  before { FB::Auth.save_cache(stale_cache) }

  describe "log --dry-run" do
    context "table output" do
      When(:stdout) {
        capture_stdout {
          FB::Cli.start(["log", "--client", "Acme Corp", "--duration", "1.5",
                         "--note", "test work", "--yes", "--dry-run"])
        }
      }
      Then { stdout.include?("Time entry created!") }
    end

    context "json output includes _dry_run metadata" do
      When(:stdout) {
        capture_stdout {
          FB::Cli.start(["log", "--client", "Acme Corp", "--duration", "1.5",
                         "--note", "test work", "--yes", "--dry-run", "--format", "json"])
        }
      }
      Then {
        json = JSON.parse(stdout)
        json["_dry_run"]["simulated"] == true
      }
    end
  end

  describe "edit --dry-run" do
    context "table output" do
      When(:stdout) {
        capture_stdout {
          FB::Cli.start(["edit", "--id", "999", "--duration", "2.0",
                         "--yes", "--dry-run"])
        }
      }
      Then { stdout.include?("Time entry 999 updated.") }
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

  describe "delete --dry-run" do
    context "table output" do
      When(:stdout) {
        capture_stdout {
          FB::Cli.start(["delete", "--id", "999", "--yes", "--dry-run"])
        }
      }
      Then { stdout.include?("Time entry 999 deleted.") }
    end

    context "json output includes _dry_run metadata" do
      When(:stdout) {
        capture_stdout {
          FB::Cli.start(["delete", "--id", "999", "--yes", "--dry-run", "--format", "json"])
        }
      }
      Then {
        json = JSON.parse(stdout)
        json["_dry_run"]["simulated"] == true
      }
    end
  end

  describe "clients --dry-run" do
    context "table output (uses stale cache, no HTTP)" do
      When(:stdout) {
        capture_stdout { FB::Cli.start(["clients", "--dry-run"]) }
      }
      Then { stdout.include?("Acme Corp") }
    end

    context "json output includes _dry_run metadata" do
      When(:stdout) {
        capture_stdout { FB::Cli.start(["clients", "--dry-run", "--format", "json"]) }
      }
      Then {
        json = JSON.parse(stdout)
        json["_dry_run"]["simulated"] == true && json["data"].is_a?(Array)
      }
    end
  end

  describe "stderr banner" do
    When(:stderr) {
      capture_stderr { capture_stdout { FB::Cli.start(["version", "--dry-run"]) } }
    }
    Then { stderr.include?("[DRY RUN] No changes will be made.") }
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
docker compose run --rm --entrypoint rspec fb spec/fb/cli_spec.rb -e "dry-run integration"
```

Expected: FAIL (likely WebMock errors or wrong output)

- [ ] **Step 3: Run tests to verify they pass**

After Tasks 1–4 are complete, these tests should now pass without any changes:

```bash
docker compose run --rm --entrypoint rspec fb spec/fb/cli_spec.rb -e "dry-run integration"
```

Expected: PASS

- [ ] **Step 4: Run the full test suite**

```bash
docker compose run --rm --entrypoint rspec fb
```

Expected: all tests pass

- [ ] **Step 5: Commit**

```bash
git add spec/fb/cli_spec.rb
git commit -m "test(cli): add dry-run integration tests"
```

---

### Task 6: Update documentation

**Files:**
- Modify: `AGENTS.md`

- [ ] **Step 1: Add dry-run section to AGENTS.md**

In the `Auth Flow` section of `AGENTS.md`, add a new subsection after the existing auth subcommands:

```markdown
### Dry-Run Mode

All commands support `--dry-run` (global class option). When set:

- Auth is bypassed — no token refresh, no config requirement
- Read API calls use cached data ignoring freshness (stale cache is fine); empty cache returns `[]`
- Write API calls (`create_time_entry`, `update_time_entry`, `delete_time_entry`) return mock responses without hitting the network
- A `[DRY RUN] No changes will be made.` banner is printed to stderr before the command
- With `--format json`, all output is wrapped with a `"_dry_run": {"simulated": true}` metadata key; array results are nested under `"data"`

Implementation uses `Thread.current[:fb_dry_run]` set in `invoke_command` with `ensure` cleanup. Dry-run branches are added as guards at the top of ~9 leaf methods in `Auth` and `Api`. All business logic runs unchanged.
```

- [ ] **Step 2: Commit**

```bash
git add AGENTS.md
git commit -m "docs: document --dry-run mode in AGENTS.md"
```

---

## Self-Review

**Spec coverage:**
- `--dry-run` global flag ✓ Task 1
- Auth bypass (`valid_access_token`, `require_config`) ✓ Task 2
- `cached_data` ignores freshness ✓ Task 3
- `fetch_all_pages` returns `[]` ✓ Task 3
- `fetch_services` direct HTTParty call bypassed ✓ Task 3
- `fetch_time_entry` mock ✓ Task 3
- Write mocks (`create`, `update`, `delete`) ✓ Task 4
- `[DRY RUN]` stderr banner ✓ Task 1 + Task 5
- `_dry_run` JSON metadata (all commands) ✓ Task 1 (`invoke_command` wrapping) + Task 5
- No HTTP calls made ✓ Task 5 (WebMock enforces)
- Stale cache tolerance ✓ Tasks 3 + 5
- AGENTS.md docs ✓ Task 6

**Placeholder scan:** No TBDs. All code blocks are complete.

**Type consistency:** `Thread.current[:fb_dry_run]` used consistently across all files. `_dry_run` key name used consistently. `"dry-run-token"` string consistent between Auth and Api headers.
