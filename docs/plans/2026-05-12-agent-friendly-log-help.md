# Agent-Friendly Log Help Implementation Plan

**Goal:** Make `fb log` easier for scripted callers to recover from common parse and help mistakes.

**Architecture:** Keep `--duration` and `--note` as the canonical options while adding Thor aliases for common guesses. Add command-specific help text through Thor's existing description APIs, and add a narrow Thor parse-error hook that improves `fb log` unknown-option messages without changing command execution paths.

**Tech Stack:** Ruby, Thor, RSpec, rspec-given, WebMock.

---

### Task 0: Post This Design To Issue #18

**Files:**
- Read: `docs/plans/2026-05-12-agent-friendly-log-help.md`

- [ ] Post the full text of this plan to GitHub issue #18 as a comment so the implementation design is durable in the tracker.

Run:

```bash
gh issue comment 18 --repo parasquid/freshbooks-cli --body-file docs/plans/2026-05-12-agent-friendly-log-help.md
```

Expected: GitHub accepts the comment.

### Task 1: Add Failing Specs For Log Aliases

**Files:**
- Modify: `spec/freshbooks/cli_spec.rb`

- [ ] Add a `log` spec proving `--hours` and `--notes` work like `--duration` and `--note`.

Add this context under `describe "log"` after the existing non-interactive JSON spec:

```ruby
    context "non-interactive accepts common duration and note aliases" do
      Given { stub_log_apis }
      When(:output) {
        capture_stdout {
          FreshBooks::CLI::Commands.start(["log", "--client", "Acme Corp", "--hours", "2.5", "--notes", "test work", "--yes", "--format", "json"])
        }
      }
      Then {
        json = JSON.parse(output)
        json["result"]["time_entry"]["duration"] == 9000 &&
          json["result"]["time_entry"]["note"] == "test work"
      }
    end
```

- [ ] Run the focused spec and confirm it fails because Thor does not recognize `--hours` or `--notes`.

Run:

```bash
bundle exec rspec spec/freshbooks/cli_spec.rb:717
```

Expected: FAIL with an unknown option mentioning `--hours`.

### Task 2: Implement Log And Edit Aliases

**Files:**
- Modify: `lib/freshbooks/cli.rb`

- [ ] Add aliases to the existing options:

```ruby
      method_option :duration, type: :numeric, aliases: "--hours", desc: "Duration in hours (e.g. 2.5)"
      method_option :note, type: :string, aliases: "--notes", desc: "Work description"
```

Apply the same aliases to the `edit` command:

```ruby
      method_option :duration, type: :numeric, aliases: "--hours", desc: "New duration in hours"
      method_option :note, type: :string, aliases: "--notes", desc: "New note"
```

- [ ] Run the focused log spec and confirm it passes.

Run:

```bash
bundle exec rspec spec/freshbooks/cli_spec.rb:717
```

Expected: PASS.

### Task 3: Add Failing Specs For Log Help

**Files:**
- Modify: `spec/freshbooks/cli_spec.rb`

- [ ] Add a spec proving `fb log --help` exits successfully and prints command-specific guidance.

Add this near the existing `describe "help command"` block:

```ruby
  describe "log help" do
    When(:output) {
      capture_stdout {
        FreshBooks::CLI::Commands.start(["log", "--help"])
      }
    }
    Then { output.include?("fb log [--client NAME] [--project NAME] [--service NAME] --duration HOURS --note TEXT") }
    Then { output.include?("--hours") }
    Then { output.include?("fb log --project \"Sample Project\" --service \"Development\" --duration 0.5 --note \"Reviewed pull requests\" --yes") }
  end
```

- [ ] Run the focused help spec and confirm it fails because current help is too terse or treated as invalid.

Run:

```bash
bundle exec rspec spec/freshbooks/cli_spec.rb:<new-line-number>
```

Expected: FAIL before the help text is added.

### Task 4: Implement Rich Log Help

**Files:**
- Modify: `lib/freshbooks/cli.rb`

- [ ] Replace the current `desc "log", "Log a time entry"` line with a richer usage and long description:

```ruby
      desc "log [--client NAME] [--project NAME] [--service NAME] --duration HOURS --note TEXT [--date YYYY-MM-DD] [--internal] [--yes]",
        "Log a time entry"
      long_desc <<~DESC
        Log a FreshBooks time entry.

        Non-interactive usage requires --duration and --note. Use --client when multiple clients exist, or --internal with --project for internal work.

        Examples:
          fb log --project "Sample Project" --service "Development" --duration 0.5 --note "Reviewed pull requests" --yes
          fb log --internal --project "Admin" --hours 1 --notes "Planning" --yes
      DESC
```

- [ ] Run the focused help spec and confirm it passes.

Run:

```bash
bundle exec rspec spec/freshbooks/cli_spec.rb:<new-line-number>
```

Expected: PASS.

### Task 5: Add Failing Spec For Unknown Log Option Guidance

**Files:**
- Modify: `spec/freshbooks/cli_spec.rb`

- [ ] Add a spec proving unknown `fb log` flags return actionable guidance.

Add this under `describe "log"`:

```ruby
    context "unknown log option prints actionable guidance" do
      When(:result) {
        capture_stderr {
          capture_stdout {
            begin
              FreshBooks::CLI::Commands.start(["log", "--duration", "0.5", "--details", "x"])
            rescue SystemExit => e
              e
            end
          }
        }
      }
      Then { result.include?("Unknown option: --details") }
      Then { result.include?("fb log requires:") }
      Then { result.include?("--duration HOURS") }
      Then { result.include?("--note TEXT") }
      Then { result.include?("Example:") }
    end
```

- [ ] Run the focused spec and confirm it fails because current Thor output is terse.

Run:

```bash
bundle exec rspec spec/freshbooks/cli_spec.rb:<new-line-number>
```

Expected: FAIL before custom guidance exists.

### Task 6: Implement Narrow Unknown Option Guidance

**Files:**
- Modify: `lib/freshbooks/cli.rb`

- [ ] Add a class-level Thor failure hook that only special-cases `fb log` unknown options and delegates everything else to the default behavior.

Add this near `self.exit_on_failure?`:

```ruby
      def self.dispatch(m, args, options, config)
        super
      rescue Thor::UnknownArgumentError, Thor::UnknownArgumentError => e
        raise unless m.to_s == "log"

        unknown_option = e.message[/--[A-Za-z0-9_-]+/]
        message = log_parse_error_message(unknown_option, e.message)
        $stderr.puts message
        exit(1)
      end
```

Then add a helper:

```ruby
      def self.log_parse_error_message(option, fallback)
        suggestion = { "--hours" => "--duration", "--notes" => "--note" }[option]
        lines = ["Unknown option: #{option || fallback}"]
        lines << "Did you mean: #{suggestion}" if suggestion
        lines.concat([
          "",
          "fb log requires:",
          "  --duration HOURS",
          "  --note TEXT",
          "",
          "Example:",
          '  fb log --project "Sample Project" --service "Development" --duration 0.5 --note "Reviewed pull requests" --yes'
        ])
        lines.join("\n")
      end
```

If Thor exposes the error as a different class in this version, inspect the failing spec output and catch that exact Thor class.

- [ ] Run the focused unknown-option spec and confirm it passes.

Run:

```bash
bundle exec rspec spec/freshbooks/cli_spec.rb:<new-line-number>
```

Expected: PASS.

### Task 7: Update Documentation

**Files:**
- Modify: `README.md`
- Modify: `AGENTS.md`
- Modify if present/relevant: `skills/freshbooks/SKILL.md`

- [ ] Document that `fb log` accepts `--hours`/`--notes` as aliases for `--duration`/`--note`, while keeping the canonical names clear.
- [ ] Document that `fb log --help` is the first recovery path for scripted callers that need command shape examples.

### Task 8: Full Verification

**Files:**
- No source edits.

- [ ] Run the full suite.

Run:

```bash
bundle exec rspec
```

Expected: `0 failures`.

- [ ] Run whitespace verification.

Run:

```bash
git diff --check
```

Expected: no output.
