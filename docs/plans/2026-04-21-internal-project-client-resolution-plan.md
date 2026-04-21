# Internal Project Client Resolution Implementation Plan

**Goal:** Allow `fb log` and `fb edit` to work correctly with internal FreshBooks projects, keep `client_id` omitted for internal project entries, and render internal records clearly in CLI output.

**Architecture:** Keep the change narrow inside `FreshBooks::CLI::Commands` by adding a shared project/client resolution layer for `log` and `edit`, then reuse small display helpers for `entries`, `status`, `projects`, and interactive pickers. Preserve existing cached/default client behavior for normal flows while forcing a fresh project lookup only on internal or project-driven resolution paths.

**Tech Stack:** Ruby, Thor, RSpec with rspec-given, WebMock, FreshBooks REST API via HTTParty

---

## File Map

- Modify: `lib/freshbooks/cli.rb`
  Responsibility: add `--internal`, implement project-first resolution for `log` and `edit`, omit `client_id` for internal-project payloads, add internal display helpers, and update help JSON text.
- Modify: `spec/freshbooks/cli_spec.rb`
  Responsibility: add failing and passing CLI specs for internal-project logging/editing, display labels, and defaults behavior.
- Modify: `README.md`
  Responsibility: document `--internal`, internal project logging without `--client`, and updated non-interactive behavior.
- Modify: `AGENTS.md`
  Responsibility: keep repository instructions aligned with new internal-project behavior and manual verification guidance.
- Modify: `skills/freshbooks/SKILL.md`
  Responsibility: update the installed repo skill so it no longer claims `--client` is always required for deterministic logging.
- Verify manually against live data:
  Responsibility: move one Calum 1:1 entry from the parked CoinGecko project to `AI Service Design` and read it back serially.

### Task 0: Post The Approved Design Spec To Issue #2

**Files:**
- Modify: GitHub issue `#2`
- Source: `docs/plans/2026-04-21-internal-project-client-resolution-design.md`

- [x] **Step 1: Post the full approved spec text to the issue**

Run:

```bash
gh issue comment 2 --body-file docs/plans/2026-04-21-internal-project-client-resolution-design.md
```

Expected: `gh` prints the new comment URL.

- [x] **Step 2: Record the posted comment URL in the implementation notes**

Observed result:

```text
https://github.com/parasquid/freshbooks-cli/issues/2#issuecomment-4289848278
```

- [x] **Step 3: Commit the design doc before implementation planning**

Run:

```bash
git add docs/plans/2026-04-21-internal-project-client-resolution-design.md
git commit -m "docs(plans): add internal project client resolution design"
```

Expected: a commit exists on branch `2-fb-log-requires-client-even-for-internal-projects`.

### Task 1: Write Failing Specs For Internal Logging Resolution

**Files:**
- Modify: `spec/freshbooks/cli_spec.rb`
- Modify later: `lib/freshbooks/cli.rb`
- Test: `spec/freshbooks/cli_spec.rb`

- [ ] **Step 1: Add failing `log` specs for internal-project payload omission and flag conflicts**

Insert `describe "log"` examples near the existing non-interactive `log` coverage:

```ruby
    context "non-interactive with --project on an internal project and no --client" do
      Given {
        allow($stdin).to receive(:tty?).and_return(false)

        stub_request(:get, clients_url)
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: {
              "result" => {
                "clients" => [
                  { "id" => 10, "organization" => "Acme Corp", "fname" => "J", "lname" => "D" },
                  { "id" => 11, "organization" => "Globex Inc", "fname" => "G", "lname" => "X" }
                ],
                "meta" => { "pages" => 1, "page" => 1 }
              }
            }.to_json
          )

        stub_request(:get, projects_url)
          .with(query: hash_including("page" => 1, "per_page" => 100))
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: {
              "result" => {
                "projects" => [
                  {
                    "id" => 12375603,
                    "title" => "AI Service Design",
                    "client_id" => nil,
                    "internal" => true,
                    "active" => true,
                    "services" => [{ "id" => 15770631, "name" => "Meetings", "billable" => true }]
                  }
                ],
                "meta" => { "pages" => 1, "page" => 1 }
              }
            }.to_json
          )

        stub_request(:post, time_entries_url)
          .with { |req|
            payload = JSON.parse(req.body)
            entry = payload.fetch("time_entry")
            entry["project_id"] == 12375603 &&
              entry["service_id"] == 15770631 &&
              !entry.key?("client_id")
          }
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { "result" => { "time_entry" => { "id" => 777 } } }.to_json
          )
      }
      When(:output) {
        capture_stdout {
          FreshBooks::CLI::Commands.start([
            "log", "--project", "AI Service Design", "--service", "Meetings",
            "--duration", "0.5", "--note", "Calum 1:1", "--yes", "--format", "json"
          ])
        }
      }
      Then { JSON.parse(output)["result"]["time_entry"]["id"] == 777 }
      And  { assert_requested(:post, time_entries_url) }
    end

    context "non-interactive with --internal and --client aborts" do
      Given { allow($stdin).to receive(:tty?).and_return(false) }
      When(:result) {
        invoke_cli_command(
          :log,
          client: "Acme Corp",
          project: "AI Service Design",
          duration: 0.5,
          note: "Calum 1:1",
          yes: true,
          internal: true,
          no_interactive: false,
          stub_abort: true
        )
      }
      Then { result.is_a?(CliAbort) }
    end

    context "non-interactive with --internal on a client-backed project aborts" do
      Given {
        allow($stdin).to receive(:tty?).and_return(false)
        stub_log_apis
        stub_request(:get, projects_url)
          .with(query: hash_including("page" => 1, "per_page" => 100))
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: {
              "result" => {
                "projects" => [
                  { "id" => 20, "title" => "Client Project", "client_id" => 10, "internal" => false, "active" => true }
                ],
                "meta" => { "pages" => 1, "page" => 1 }
              }
            }.to_json
          )
      }
      When(:result) {
        invoke_cli_command(
          :log,
          project: "Client Project",
          duration: 0.5,
          note: "Calum 1:1",
          yes: true,
          internal: true,
          no_interactive: false,
          stub_abort: true
        )
      }
      Then { result.is_a?(CliAbort) }
    end
```

- [ ] **Step 2: Run the targeted `log` specs and confirm they fail before implementation**

Run:

```bash
bundle exec rspec spec/freshbooks/cli_spec.rb \
  --example "non-interactive with --project on an internal project and no --client" \
  --example "non-interactive with --internal and --client aborts" \
  --example "non-interactive with --internal on a client-backed project aborts"
```

Expected: FAIL because `log` still requires client-first resolution and still sends `client_id`.

- [ ] **Step 3: Implement shared project/client resolution helpers and the `log` path**

Add `method_option :internal` to `log`, then add helper methods in `lib/freshbooks/cli.rb`:

```ruby
      method_option :internal, type: :boolean, default: false, desc: "Log to an internal project with no client"
      def log
        Auth.valid_access_token
        defaults = Auth.load_defaults

        context = resolve_entry_context_for_log(defaults)
        project = context[:project]
        service = select_service(defaults, project)
        date = pick_date
        duration_hours = pick_duration
        note = pick_note

        unless options[:format] == "json"
          puts "\n--- Time Entry Summary ---"
          puts "  Client:   #{display_client_label(context[:client], project)}"
          puts "  Project:  #{project ? project["title"] : "(none)"}"
          puts "  Service:  #{service ? service["name"] : "(none)"}"
          puts "  Date:     #{date}"
          puts "  Duration: #{duration_hours}h"
          puts "  Note:     #{note}"
          puts "--------------------------\n\n"
        end

        entry = {
          "is_logged" => true,
          "duration" => (duration_hours * 3600).to_i,
          "note" => note,
          "started_at" => normalize_datetime(date)
        }
        entry["client_id"] = context[:client]["id"] if context[:client]
        entry["project_id"] = project["id"] if project
        entry["service_id"] = service["id"] if service

        result = Api.create_time_entry(entry)
        puts(options[:format] == "json" ? JSON.pretty_generate(result) : "Time entry created!")

        new_defaults = {}
        new_defaults["client_id"] = context[:client]["id"] if context[:client]
        new_defaults["project_id"] = project["id"] if project
        new_defaults["service_id"] = service["id"] if service
        Auth.save_defaults(new_defaults)
      end

      def resolve_entry_context_for_log(defaults)
        validate_internal_flag_usage!

        if options[:project] && (!options[:client] || options[:internal])
          project = resolve_project_by_name(options[:project], force: true)
          assert_internal_project_match!(project)
          client = project_internal?(project) ? nil : resolve_client_for_project(project, defaults)
          return { client: client, project: project }
        end

        client = select_client(defaults)
        project = select_project(client["id"], defaults)
        { client: client, project: project }
      end

      def resolve_project_by_name(name, force: false)
        projects = Spinner.spin("Fetching projects") { Api.fetch_projects(force: force) }
        match = projects.find { |p| p["title"].downcase == name.downcase }
        abort("Project not found: #{name}") unless match
        match
      end

      def project_internal?(project)
        project["internal"] || project["client_id"].nil?
      end

      def validate_internal_flag_usage!
        abort("Cannot combine --client with --internal.") if options[:client] && options[:internal]
        abort("--internal requires --project.") if options[:internal] && !options[:project]
      end

      def assert_internal_project_match!(project)
        abort("Project #{project["title"]} is not internal.") if options[:internal] && !project_internal?(project)
        if options[:client] && project_internal?(project)
          abort("Cannot combine --client with internal project #{project["title"]}.")
        end
      end

      def resolve_client_for_project(project, defaults)
        clients = Spinner.spin("Fetching clients") { Api.fetch_clients }
        match = clients.find { |c| c["id"].to_i == project["client_id"].to_i }
        return match if match

        default_client = clients.find { |c| c["id"].to_i == defaults["client_id"].to_i }
        return default_client if default_client && default_client["id"].to_i == project["client_id"].to_i

        abort("Client not found for project #{project["title"]}.")
      end
```

- [ ] **Step 4: Re-run the targeted `log` specs and make them pass**

Run:

```bash
bundle exec rspec spec/freshbooks/cli_spec.rb \
  --example "non-interactive with --project on an internal project and no --client" \
  --example "non-interactive with --internal and --client aborts" \
  --example "non-interactive with --internal on a client-backed project aborts"
```

Expected: PASS for the new internal `log` coverage.

- [ ] **Step 5: Commit the logging resolution work**

Run:

```bash
git add lib/freshbooks/cli.rb spec/freshbooks/cli_spec.rb
git commit -m "feat(log): support internal project resolution"
```

### Task 2: Write Failing Specs For Internal Editing Resolution

**Files:**
- Modify: `spec/freshbooks/cli_spec.rb`
- Modify later: `lib/freshbooks/cli.rb`
- Test: `spec/freshbooks/cli_spec.rb`

- [ ] **Step 1: Add failing `edit` specs for moving entries onto internal projects**

Add examples under `describe "edit"`:

```ruby
    context "scripted edit moves an entry to an internal project and omits client_id" do
      Given {
        stub_request(:get, %r{api\.freshbooks\.com/timetracking/business/12345/time_entries/42})
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: {
              "result" => {
                "time_entry" => {
                  "id" => 42,
                  "duration" => 1800,
                  "note" => "Tristan : Calum 1:1",
                  "started_at" => "2026-04-21T00:00:00Z",
                  "client_id" => 1084081,
                  "project_id" => 12668685,
                  "service_id" => 15770631,
                  "is_logged" => true
                }
              }
            }.to_json
          )

        FreshBooks::CLI::Auth.save_cache(
          "updated_at" => Time.now.to_i - 60,
          "clients" => { "1084081" => "CoinGecko" },
          "projects" => { "12668685" => "Ad Platform & Token Listing", "12375603" => "AI Service Design" },
          "services" => { "15770631" => "Meetings", "15770545" => "General" }
        )

        stub_request(:get, projects_url)
          .with(query: hash_including("page" => 1, "per_page" => 100))
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: {
              "result" => {
                "projects" => [
                  {
                    "id" => 12375603,
                    "title" => "AI Service Design",
                    "client_id" => nil,
                    "internal" => true,
                    "active" => true,
                    "services" => [{ "id" => 15770631, "name" => "Meetings", "billable" => true }]
                  }
                ],
                "meta" => { "pages" => 1, "page" => 1 }
              }
            }.to_json
          )

        stub_request(:put, %r{api\.freshbooks\.com/timetracking/business/12345/time_entries/42})
          .with { |req|
            payload = JSON.parse(req.body)
            entry = payload.fetch("time_entry")
            entry["project_id"] == 12375603 &&
              entry["service_id"] == 15770631 &&
              !entry.key?("client_id")
          }
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { "result" => { "time_entry" => { "id" => 42 } } }.to_json
          )
      }
      When(:output) {
        capture_stdout {
          FreshBooks::CLI::Commands.start([
            "edit", "--id", "42", "--project", "AI Service Design",
            "--service", "Meetings", "--yes", "--format", "json"
          ])
        }
      }
      Then { JSON.parse(output)["result"]["time_entry"]["id"] == 42 }
      And  { assert_requested(:put, %r{api\.freshbooks\.com/timetracking/business/12345/time_entries/42}) }
    end

    context "scripted edit with --internal on a client-backed project aborts" do
      Given {
        stub_request(:get, %r{api\.freshbooks\.com/timetracking/business/12345/time_entries/42})
          .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: {
            "result" => { "time_entry" => { "id" => 42, "duration" => 1800, "note" => "test", "started_at" => "2026-04-21T00:00:00Z", "client_id" => 10, "project_id" => 20, "service_id" => 30, "is_logged" => true } }
          }.to_json)
      }
      When(:result) {
        invoke_cli_command(:edit, id: 42, project: "Client Project", internal: true, yes: true, no_interactive: true, stub_abort: true)
      }
      Then { result.is_a?(CliAbort) }
    end
```

- [ ] **Step 2: Run the targeted `edit` specs and confirm they fail before implementation**

Run:

```bash
bundle exec rspec spec/freshbooks/cli_spec.rb \
  --example "scripted edit moves an entry to an internal project and omits client_id" \
  --example "scripted edit with --internal on a client-backed project aborts"
```

Expected: FAIL because `build_edit_fields` currently preserves the old `client_id`.

- [ ] **Step 3: Implement project-aware `edit` resolution**

Update `edit`, `build_edit_fields`, and shared helpers in `lib/freshbooks/cli.rb`:

```ruby
      method_option :internal, type: :boolean, default: false, desc: "Move entry to an internal project with no client"
      def edit
        Auth.valid_access_token

        entry_id = options[:id] || (abort("Missing required flag: --id") unless interactive?)
        entry_id ||= pick_entry_interactive("edit")

        entry = Spinner.spin("Fetching time entry") { Api.fetch_time_entry(entry_id) }
        abort("Time entry not found.") unless entry

        maps = Spinner.spin("Resolving names") { Api.build_name_maps }
        has_edit_flags = options[:duration] || options[:note] || options[:date] || options[:client] || options[:project] || options[:service] || options[:internal]
        scripted = has_edit_flags || !interactive?

        fields = build_edit_fields(entry, maps, scripted)
        current_project = maps[:projects][entry["project_id"].to_s] || "-"
        current_hours = (entry["duration"].to_i / 3600.0).round(2)
        new_hours = fields["duration"] ? (fields["duration"].to_i / 3600.0).round(2) : current_hours

        unless options[:format] == "json"
          puts "\n--- Edit Summary ---"
          puts "  Date:     #{fields["started_at"] || entry["started_at"]}"
          puts "  Client:   #{display_client_label_from_ids(fields["client_id"], fields["project_id"], maps)}"
          puts "  Project:  #{fields["project_id"] ? maps[:projects][fields["project_id"].to_s] : current_project}"
          puts "  Duration: #{new_hours}h"
          puts "  Note:     #{fields["note"] || entry["note"]}"
          puts "--------------------\n\n"
        end

        result = Spinner.spin("Updating time entry") { Api.update_time_entry(entry_id, fields.compact) }
        puts(options[:format] == "json" ? JSON.pretty_generate(result) : "Time entry #{entry_id} updated.")
      end

      def build_edit_fields(entry, maps, scripted)
        fields = {
          "started_at" => entry["started_at"],
          "is_logged" => entry["is_logged"] || true,
          "duration" => entry["duration"],
          "note" => entry["note"],
          "client_id" => entry["client_id"],
          "project_id" => entry["project_id"],
          "service_id" => entry["service_id"]
        }

        return fields unless scripted

        fields["duration"] = (options[:duration] * 3600).to_i if options[:duration]
        fields["note"] = options[:note] if options[:note]
        fields["started_at"] = normalize_datetime(options[:date]) if options[:date]

        if options[:project]
          project = resolve_project_by_name(options[:project], force: true)
          assert_internal_project_match!(project)
          fields["project_id"] = project["id"]
          if project_internal?(project)
            fields.delete("client_id")
          else
            fields["client_id"] = project["client_id"].to_i
          end
        elsif options[:client]
          client_id = maps[:clients].find { |_id, name| name.downcase == options[:client].downcase }&.first
          abort("Client not found: #{options[:client]}") unless client_id
          fields["client_id"] = client_id.to_i
        end

        if options[:internal] && !options[:project]
          abort("--internal requires --project.")
        end

        if options[:service]
          service_id = maps[:services].find { |_id, name| name.downcase == options[:service].downcase }&.first
          abort("Service not found: #{options[:service]}") unless service_id
          fields["service_id"] = service_id.to_i
        end

        fields
      end
```

- [ ] **Step 4: Re-run the targeted `edit` specs and make them pass**

Run:

```bash
bundle exec rspec spec/freshbooks/cli_spec.rb \
  --example "scripted edit moves an entry to an internal project and omits client_id" \
  --example "scripted edit with --internal on a client-backed project aborts"
```

Expected: PASS for the new internal `edit` coverage.

- [ ] **Step 5: Commit the editing resolution work**

Run:

```bash
git add lib/freshbooks/cli.rb spec/freshbooks/cli_spec.rb
git commit -m "feat(edit): support internal project moves"
```

### Task 3: Add Internal Display Support For Read Paths

**Files:**
- Modify: `spec/freshbooks/cli_spec.rb`
- Modify later: `lib/freshbooks/cli.rb`
- Test: `spec/freshbooks/cli_spec.rb`

- [ ] **Step 1: Add failing specs for internal labels in `projects`, `entries`, and `status`**

Add coverage that table output uses `Internal`:

```ruby
  describe "projects" do
    context "table output shows Internal for internal projects" do
      Given {
        stub_request(:get, projects_url)
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: {
              "result" => {
                "projects" => [{ "id" => 12375603, "title" => "AI Service Design", "client_id" => nil, "internal" => true, "active" => true }],
                "meta" => { "pages" => 1, "page" => 1 }
              }
            }.to_json
          )
        FreshBooks::CLI::Auth.save_cache("updated_at" => Time.now.to_i - 60, "clients" => {}, "projects" => {}, "services" => {})
      }
      When(:output) { capture_stdout { FreshBooks::CLI::Commands.start(["projects"]) } }
      Then { output.include?("AI Service Design") }
      And  { output.include?("Internal") }
    end
  end

  describe "entries" do
    context "table output shows Internal for internal entries" do
      Given {
        stub_request(:get, time_entries_url)
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: {
              "result" => {
                "time_entries" => [
                  { "id" => 42, "started_at" => "2026-04-13T00:00:00Z", "client_id" => nil, "project_id" => 12375603, "service_id" => 15770631, "note" => "Calum 1:1", "duration" => 1800 }
                ],
                "meta" => { "pages" => 1, "page" => 1 }
              }
            }.to_json
          )
        FreshBooks::CLI::Auth.save_cache(
          "updated_at" => Time.now.to_i - 60,
          "clients" => {},
          "projects" => { "12375603" => "AI Service Design" },
          "services" => { "15770631" => "Meetings" }
        )
      }
      When(:output) { capture_stdout { FreshBooks::CLI::Commands.start(["entries", "--from", "2026-04-13", "--to", "2026-04-13"]) } }
      Then { output.include?("Internal") }
    end
  end
```

- [ ] **Step 2: Run the read-path specs and confirm they fail before implementation**

Run:

```bash
bundle exec rspec spec/freshbooks/cli_spec.rb \
  --example "table output shows Internal for internal projects" \
  --example "table output shows Internal for internal entries"
```

Expected: FAIL because nil `client_id` currently renders as blank or `-`.

- [ ] **Step 3: Add shared display helpers and update read paths**

Add helpers in `lib/freshbooks/cli.rb` and use them in `entries`, `projects`, `status`, and `pick_entry_interactive`:

```ruby
      def display_client_label(client, project = nil)
        return "Internal" if client.nil? && project && project_internal?(project)
        return "Internal" if client.nil?
        display_name(client)
      end

      def display_client_label_from_entry(entry, maps)
        return "Internal" if entry["client_id"].nil?
        maps[:clients][entry["client_id"].to_s] || entry["client_id"].to_s
      end

      def display_client_label_from_project(project, maps)
        return "Internal" if project_internal?(project)
        maps[:clients][project["client_id"].to_s] || "-"
      end

      def display_client_label_from_ids(client_id, project_id, maps)
        return "Internal" if client_id.nil?
        maps[:clients][client_id.to_s] || client_id.to_s
      end
```

Update callers:

```ruby
          client = display_client_label_from_entry(e, maps)
```

```ruby
        by_client = entries.group_by { |e| display_client_label_from_entry(e, maps) }
```

```ruby
          client_name = display_client_label_from_project(p, maps)
```

```ruby
          client = display_client_label_from_entry(e, maps)
```

- [ ] **Step 4: Re-run the read-path specs and make them pass**

Run:

```bash
bundle exec rspec spec/freshbooks/cli_spec.rb \
  --example "table output shows Internal for internal projects" \
  --example "table output shows Internal for internal entries"
```

Expected: PASS for the new internal display coverage.

- [ ] **Step 5: Commit the display support work**

Run:

```bash
git add lib/freshbooks/cli.rb spec/freshbooks/cli_spec.rb
git commit -m "feat(cli): label internal projects and entries"
```

### Task 4: Run The Full Relevant Test Slice

**Files:**
- Verify: `spec/freshbooks/cli_spec.rb`
- Verify optionally: `spec/freshbooks/api_spec.rb`

- [ ] **Step 1: Run the full CLI spec file after the focused changes**

Run:

```bash
bundle exec rspec spec/freshbooks/cli_spec.rb
```

Expected: PASS for the full CLI suite.

- [ ] **Step 2: If the CLI suite reveals cache or payload regressions, fix them immediately in the touched files**

Likely fix shape if needed:

```ruby
        new_defaults = {}
        new_defaults["client_id"] = context[:client]["id"] if context[:client]
        new_defaults["project_id"] = project["id"] if project
        new_defaults["service_id"] = service["id"] if service
        Auth.save_defaults(new_defaults)
```

Run after each fix:

```bash
bundle exec rspec spec/freshbooks/cli_spec.rb
```

Expected: PASS.

- [ ] **Step 3: Commit the test-green integration point**

Run:

```bash
git add lib/freshbooks/cli.rb spec/freshbooks/cli_spec.rb
git commit -m "test(cli): cover internal project client resolution"
```

### Task 5: Manual Live Verification Against The Calum 1:1 Entry

**Files:**
- Verify live FreshBooks data only
- No automated fixture changes

- [ ] **Step 1: Find the parked Calum 1:1 entry serially**

Run:

```bash
bundle exec bin/fb entries --format json
```

Expected: find the entry whose note contains:

```text
Tristan : Calum 1:1 (parked here; AI Service Design not easily selectable via fb CLI for no-client projects)
```

- [ ] **Step 2: Move that live entry to the internal `AI Service Design` project**

Run:

```bash
bundle exec bin/fb edit --id <entry-id> --project "AI Service Design" --service "Meetings" --yes --format json
```

Expected: JSON response showing the edited entry id. Run serially, not in parallel with other auth-backed commands.

- [ ] **Step 3: Read the updated entry back and verify `client_id` is null**

Run:

```bash
bundle exec bin/fb entries --format json
```

Expected: the edited record now shows:

```json
{
  "id": <entry-id>,
  "project_id": 12375603,
  "client_id": null
}
```

- [ ] **Step 4: Record the manual verification result in the final delivery notes**

Capture these facts:

```text
- verified against live FreshBooks data
- moved one Calum 1:1 entry onto AI Service Design
- resulting entry read back with client_id: null
```

- [ ] **Step 5: Commit only repo changes, not live-data state**

Run:

```bash
git status --short
```

Expected: only code/docs files are staged or modified; no extra files are created for the manual verification step.

### Task 6: Update Help Text And All Related Documentation

**Files:**
- Modify: `lib/freshbooks/cli.rb`
- Modify: `README.md`
- Modify: `AGENTS.md`
- Modify: `skills/freshbooks/SKILL.md`

- [ ] **Step 1: Update Thor option descriptions and help JSON in `lib/freshbooks/cli.rb`**

Adjust help text so internal behavior is obvious:

```ruby
      method_option :internal, type: :boolean, default: false, desc: "Use an internal project and omit client_id"
```

Update `help_json` command docs to describe:

```ruby
                "--client" => "Client name (required only for client-backed project selection in non-interactive mode)",
                "--project" => "Project name (can be internal; internal projects may be used without --client)",
                "--internal" => "Force internal-project resolution; requires --project and conflicts with --client"
```

- [ ] **Step 2: Update `README.md` examples and behavior notes**

Add or revise examples like:

```bash
fb log --project "AI Service Design" --service "Meetings" --duration 0.5 --note "Calum 1:1" --yes --format json
fb log --internal --project "AI Service Design" --service "Meetings" --duration 0.5 --note "Calum 1:1" --yes --format json
fb edit --id 12345 --project "AI Service Design" --service "Meetings" --yes --format json
```

Document:

```text
- Internal projects are detected from a fresh project lookup.
- Internal project entries omit client_id.
- Normal client-first logging still uses cached/default client behavior.
- CLI table output shows Internal for internal projects and entries.
```

- [ ] **Step 3: Update `AGENTS.md` and `skills/freshbooks/SKILL.md`**

Apply the same contract updates:

```text
- `fb log` does not require `--client` for internal projects.
- `--internal` requires `--project` and conflicts with `--client`.
- `fb edit` can move an entry onto an internal project and should end up with `client_id: null`.
- Services remain project-scoped.
```

- [ ] **Step 4: Run the CLI help smoke checks**

Run:

```bash
bundle exec bin/fb help log --format json
bundle exec bin/fb help edit --format json
```

Expected: JSON output includes the updated option descriptions for `--project`, `--client`, and `--internal`.

- [ ] **Step 5: Commit the docs and help updates**

Run:

```bash
git add lib/freshbooks/cli.rb README.md AGENTS.md skills/freshbooks/SKILL.md
git commit -m "docs(cli): document internal project workflows"
```

## Self-Review Checklist

- Spec coverage:
  - `log` internal project support: Task 1
  - `edit` internal project support: Task 2
  - read/display support: Task 3
  - manual Calum 1:1 verification: Task 5
  - docs/help/skill updates: Task 6
- Placeholder scan:
  - no `TODO`, `TBD`, or “similar to above” shortcuts remain
- Type consistency:
  - helper names are consistent across the plan: `resolve_project_by_name`, `project_internal?`, `display_client_label_from_entry`
