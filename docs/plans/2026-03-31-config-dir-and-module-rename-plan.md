# Config Directory Resolution & Module Rename Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename the `FB` Ruby module to `FreshBooks::CLI` throughout, and add platform-native config directory resolution with `FRESHBOOKS_HOME` override support.

**Architecture:** The rename is purely mechanical — `git mv` each file then update the two module declaration lines. The feature adds a private `resolve_data_dir` helper to `FreshBooks::CLI::Auth` that checks `FRESHBOOKS_HOME`, falls back to legacy `~/.fb` if it exists, then uses a platform-native default (`~/Library/Application Support/freshbooks` on macOS, `~/.config/freshbooks` on Linux). Platform detection is extracted into a stubable `macos?` method.

**Tech Stack:** Ruby, RSpec with rspec-given, webmock, Docker Compose for tests.

---

### Task 0: Post design spec to GitHub issue #5

- [ ] **Step 1: Post the full design spec**

```bash
gh issue comment 5 --body "$(cat docs/plans/2026-03-31-config-dir-and-module-rename-design.md)"
```

- [ ] **Step 2: Commit**

```bash
git add docs/plans/2026-03-31-config-dir-and-module-rename-plan.md
git commit -m "docs(plans): add implementation plan for config dir resolution and module rename"
```

---

### Task 1: Create feature branch

- [ ] **Step 1: Create and switch to branch**

```bash
git checkout -b 5-support-configurable-config-directory-via-environment-variable
```

---

### Task 2: Rename version and spinner files

These files only have module declaration changes — no logic.

- [ ] **Step 1: Create the new directory and move version.rb**

```bash
mkdir -p lib/freshbooks
git mv lib/fb/version.rb lib/freshbooks/version.rb
```

- [ ] **Step 2: Update module declaration in lib/freshbooks/version.rb**

Change:
```ruby
module FB
  VERSION = "0.3.3"
end
```
To:
```ruby
module FreshBooks
  module CLI
    VERSION = "0.3.3"
  end
end
```

- [ ] **Step 3: Move spinner.rb**

```bash
git mv lib/fb/spinner.rb lib/freshbooks/spinner.rb
```

- [ ] **Step 4: Rewrite lib/freshbooks/spinner.rb with updated module namespace**

Replace the entire file content with:

```ruby
# frozen_string_literal: true

module FreshBooks
  module CLI
    module Spinner
      FRAMES = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze

      @interactive = nil

      def self.interactive=(value)
        @interactive = value
      end

      def self.interactive?
        return @interactive unless @interactive.nil?
        $stderr.tty?
      end

      def self.spin(message)
        result = nil

        unless interactive?
          result = yield
          return result
        end

        done = false
        thread = Thread.new do
          i = 0
          while !done
            $stderr.print "\r#{FRAMES[i % FRAMES.length]} #{message}"
            $stderr.flush
            i += 1
            sleep 0.08
          end
        end

        begin
          result = yield
        ensure
          done = true
          thread.join
          $stderr.print "\r✓ #{message}\n"
        end

        result
      end
    end
  end
end
```

- [ ] **Step 5: Commit**

```bash
git add lib/freshbooks/version.rb lib/freshbooks/spinner.rb
git commit -m "refactor: rename FB::VERSION and FB::Spinner to FreshBooks::CLI"
```

---

### Task 3: Rename auth.rb (rename only, feature comes later)

- [ ] **Step 1: Move the file**

```bash
git mv lib/fb/auth.rb lib/freshbooks/auth.rb
```

- [ ] **Step 2: Update module declaration in lib/freshbooks/auth.rb**

Change:
```ruby
module FB
  class Auth
```
To:
```ruby
module FreshBooks
  module CLI
    class Auth
```

Change the closing at the bottom of the file:
```ruby
  end
end
```
To:
```ruby
    end
  end
end
```

- [ ] **Step 3: Commit**

```bash
git add lib/freshbooks/auth.rb
git commit -m "refactor: rename FB::Auth to FreshBooks::CLI::Auth"
```

---

### Task 4: Rename api.rb

- [ ] **Step 1: Move the file**

```bash
git mv lib/fb/api.rb lib/freshbooks/api.rb
```

- [ ] **Step 2: Update module declaration in lib/freshbooks/api.rb**

Change:
```ruby
module FB
  class Api
```
To:
```ruby
module FreshBooks
  module CLI
    class Api
```

Change the closing at the bottom:
```ruby
  end
end
```
To:
```ruby
    end
  end
end
```

- [ ] **Step 3: Commit**

```bash
git add lib/freshbooks/api.rb
git commit -m "refactor: rename FB::Api to FreshBooks::CLI::Api"
```

---

### Task 5: Rename cli.rb (FB::Cli → FreshBooks::CLI::Commands)

- [ ] **Step 1: Move the file**

```bash
git mv lib/fb/cli.rb lib/freshbooks/cli.rb
```

- [ ] **Step 2: Update module and class declaration in lib/freshbooks/cli.rb**

Change:
```ruby
module FB
  class Cli < Thor
```
To:
```ruby
module FreshBooks
  module CLI
    class Commands < Thor
```

Change the closing at the bottom:
```ruby
  end
end
```
To:
```ruby
    end
  end
end
```

No changes needed inside the class body — `Auth`, `Api`, `Spinner` are referenced by bare name, and Ruby's constant lookup finds them via the `FreshBooks::CLI` nesting.

- [ ] **Step 3: Commit**

```bash
git add lib/freshbooks/cli.rb
git commit -m "refactor: rename FB::Cli to FreshBooks::CLI::Commands"
```

---

### Task 6: Rename main require file, update gemspec and bin

- [ ] **Step 1: Move lib/fb.rb**

```bash
git mv lib/fb.rb lib/freshbooks.rb
```

- [ ] **Step 2: Update lib/freshbooks.rb**

Change:
```ruby
require_relative "fb/version"
require_relative "fb/spinner"
require_relative "fb/auth"
require_relative "fb/api"
require_relative "fb/cli"
```
To:
```ruby
require_relative "freshbooks/version"
require_relative "freshbooks/spinner"
require_relative "freshbooks/auth"
require_relative "freshbooks/api"
require_relative "freshbooks/cli"
```

- [ ] **Step 3: Delete the now-empty lib/fb/ directory**

```bash
rmdir lib/fb
```

- [ ] **Step 4: Update fb.gemspec**

Change:
```ruby
require_relative "lib/fb/version"
```
To:
```ruby
require_relative "lib/freshbooks/version"
```

Change:
```ruby
s.version     = FB::VERSION
```
To:
```ruby
s.version     = FreshBooks::CLI::VERSION
```

- [ ] **Step 5: Update bin/fb**

Change:
```ruby
require "fb"

FB::Cli.start(ARGV)
```
To:
```ruby
require "freshbooks"

FreshBooks::CLI::Commands.start(ARGV)
```

- [ ] **Step 6: Commit**

```bash
git add lib/freshbooks.rb fb.gemspec bin/fb
git commit -m "refactor: rename main require file and update entry points"
```

---

### Task 7: Rename and update spec files

- [ ] **Step 1: Move spec files**

```bash
mkdir -p spec/freshbooks
git mv spec/fb/auth_spec.rb spec/freshbooks/auth_spec.rb
git mv spec/fb/api_spec.rb spec/freshbooks/api_spec.rb
git mv spec/fb/cli_spec.rb spec/freshbooks/cli_spec.rb
git mv spec/fb/spinner_spec.rb spec/freshbooks/spinner_spec.rb
rmdir spec/fb
```

- [ ] **Step 2: Update spec/spec_helper.rb**

Change:
```ruby
require "fb"
```
To:
```ruby
require "freshbooks"
```

Change:
```ruby
    FB::Auth.data_dir = tmpdir
    example.run
  end
  FB::Auth.instance_variable_set(:@data_dir, nil)
```
To:
```ruby
    FreshBooks::CLI::Auth.data_dir = tmpdir
    example.run
  end
  FreshBooks::CLI::Auth.data_dir = nil
```

Change:
```ruby
    allow(FB::Spinner).to receive(:spin) do |_msg, &block|
```
To:
```ruby
    allow(FreshBooks::CLI::Spinner).to receive(:spin) do |_msg, &block|
```

- [ ] **Step 3: Update spec/freshbooks/spinner_spec.rb**

Replace all occurrences of `FB::Spinner` with `FreshBooks::CLI::Spinner`.

- [ ] **Step 4: Update spec/freshbooks/auth_spec.rb**

Replace all occurrences of `FB::Auth` with `FreshBooks::CLI::Auth`.

- [ ] **Step 5: Update spec/freshbooks/api_spec.rb**

Replace all occurrences of `FB::Api` with `FreshBooks::CLI::Api`, and `FB::Auth` with `FreshBooks::CLI::Auth`.

- [ ] **Step 6: Update spec/freshbooks/cli_spec.rb**

Replace all occurrences of `FB::Cli` with `FreshBooks::CLI::Commands`, `FB::Auth` with `FreshBooks::CLI::Auth`, `FB::Api` with `FreshBooks::CLI::Api`, `FB::Spinner` with `FreshBooks::CLI::Spinner`.

- [ ] **Step 7: Commit**

```bash
git add spec/
git commit -m "refactor: update specs to use FreshBooks::CLI namespace"
```

---

### Task 8: Verify rename is clean

- [ ] **Step 1: Run the full test suite**

```bash
docker compose run --rm --entrypoint rspec fb
```

Expected: all tests pass. If failures occur, they will be namespace resolution errors — check for any remaining `FB::` references.

- [ ] **Step 2: Search for any remaining FB:: references**

```bash
grep -rn "FB::\|module FB\b\|class FB\b" lib/ spec/ bin/
```

Expected: no output. Fix any found occurrences before proceeding.

---

### Task 9: Write failing tests for `resolve_data_dir`

All new tests go in `spec/freshbooks/auth_spec.rb`. Add a new `describe ".data_dir"` block.

The tests stub `macos?` (a private method we'll add) to control platform detection, and use `Dir.mktmpdir` to simulate the legacy path.

- [ ] **Step 1: Add the failing tests**

Add to `spec/freshbooks/auth_spec.rb`:

```ruby
describe ".data_dir" do
  before do
    FreshBooks::CLI::Auth.data_dir = nil
  end

  after do
    ENV.delete("FRESHBOOKS_HOME")
    ENV.delete("XDG_CONFIG_HOME")
    FreshBooks::CLI::Auth.data_dir = nil
  end

  context "when FRESHBOOKS_HOME is set" do
    Given { ENV["FRESHBOOKS_HOME"] = "/custom/path" }
    Then { FreshBooks::CLI::Auth.data_dir == "/custom/path" }
  end

  context "when legacy ~/.fb exists" do
    Given do
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with(File.join(Dir.home, ".fb")).and_return(true)
    end
    Then { FreshBooks::CLI::Auth.data_dir == File.join(Dir.home, ".fb") }
  end

  context "on macOS with no legacy path" do
    Given do
      allow(FreshBooks::CLI::Auth).to receive(:macos?).and_return(true)
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with(File.join(Dir.home, ".fb")).and_return(false)
    end
    Then { FreshBooks::CLI::Auth.data_dir == File.join(Dir.home, "Library", "Application Support", "freshbooks") }
  end

  context "on Linux with XDG_CONFIG_HOME set and no legacy path" do
    Given do
      ENV["XDG_CONFIG_HOME"] = "/custom/config"
      allow(FreshBooks::CLI::Auth).to receive(:macos?).and_return(false)
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with(File.join(Dir.home, ".fb")).and_return(false)
    end
    Then { FreshBooks::CLI::Auth.data_dir == "/custom/config/freshbooks" }
  end

  context "on Linux with no XDG_CONFIG_HOME and no legacy path" do
    Given do
      allow(FreshBooks::CLI::Auth).to receive(:macos?).and_return(false)
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with(File.join(Dir.home, ".fb")).and_return(false)
    end
    Then { FreshBooks::CLI::Auth.data_dir == File.join(Dir.home, ".config", "freshbooks") }
  end

  context "when data_dir= is set to nil it resets to auto-resolution" do
    Given do
      FreshBooks::CLI::Auth.data_dir = "/some/explicit/path"
      FreshBooks::CLI::Auth.data_dir = nil
      allow(FreshBooks::CLI::Auth).to receive(:macos?).and_return(false)
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with(File.join(Dir.home, ".fb")).and_return(false)
    end
    Then { FreshBooks::CLI::Auth.data_dir == File.join(Dir.home, ".config", "freshbooks") }
  end
end
```

- [ ] **Step 2: Run the new tests to verify they fail**

```bash
docker compose run --rm --entrypoint rspec fb spec/freshbooks/auth_spec.rb --example "data_dir"
```

Expected: failures like `undefined method 'macos?'` and wrong return values from the old `||=` getter.

---

### Task 10: Implement `resolve_data_dir` in auth.rb

- [ ] **Step 1: Replace the `data_dir` getter and add private helpers in lib/freshbooks/auth.rb**

Replace:
```ruby
      def data_dir
        @data_dir ||= File.join(Dir.home, ".fb")
      end

      def data_dir=(path)
        @data_dir = path
      end
```
With:
```ruby
      def data_dir
        return @data_dir unless @data_dir.nil?
        resolve_data_dir
      end

      def data_dir=(path)
        @data_dir = path
      end

      private

      def macos?
        RUBY_PLATFORM.include?("darwin")
      end

      def resolve_data_dir
        return ENV["FRESHBOOKS_HOME"] if ENV["FRESHBOOKS_HOME"]
        legacy = File.join(Dir.home, ".fb")
        return legacy if File.exist?(legacy)
        if macos?
          File.join(Dir.home, "Library", "Application Support", "freshbooks")
        else
          xdg_base = ENV["XDG_CONFIG_HOME"] || File.join(Dir.home, ".config")
          File.join(xdg_base, "freshbooks")
        end
      end

      public
```

Note: `private` / `public` inside `class << self` controls singleton method visibility. `macos?` and `resolve_data_dir` are private class methods — they can be stubbed in tests via `allow(FreshBooks::CLI::Auth).to receive(:macos?)`.

- [ ] **Step 2: Run the new tests**

```bash
docker compose run --rm --entrypoint rspec fb spec/freshbooks/auth_spec.rb --example "data_dir"
```

Expected: all 6 new tests pass.

- [ ] **Step 3: Run the full auth spec to check for regressions**

```bash
docker compose run --rm --entrypoint rspec fb spec/freshbooks/auth_spec.rb
```

Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add lib/freshbooks/auth.rb spec/freshbooks/auth_spec.rb
git commit -m "feat(auth): add FRESHBOOKS_HOME and platform-native config directory resolution

New installs use ~/Library/Application Support/freshbooks (macOS) or
~/.config/freshbooks (Linux/XDG). Existing ~/.fb users are unaffected.

Closes #5"
```

---

### Task 11: Run full test suite

- [ ] **Step 1: Run all tests**

```bash
docker compose run --rm --entrypoint rspec fb
```

Expected: all tests pass with no failures or errors.

---

### Task 12: Update documentation

**Files:** `AGENTS.md`, `README.md` (if it exists and references `~/.fb` or module names).

- [ ] **Step 1: Check README for references to update**

```bash
grep -n "FB::\|~/.fb\|FB module\|require.*fb" README.md 2>/dev/null || echo "No README or no matches"
```

- [ ] **Step 2: Update AGENTS.md**

In the **Architecture** section, update:
- `FB::Auth` → `FreshBooks::CLI::Auth`
- `FB::Api` → `FreshBooks::CLI::Api`
- `FB::Cli` → `FreshBooks::CLI::Commands`
- `FB::Spinner` → `FreshBooks::CLI::Spinner`
- `Auth.data_dir` description: add `FRESHBOOKS_HOME` env var, platform-native resolution, and legacy `~/.fb` fallback
- `lib/fb/auth.rb` → `lib/freshbooks/auth.rb` (and similarly for other files)

In the **Testing Conventions** section, update:
- `FB::Auth.data_dir=` references to `FreshBooks::CLI::Auth.data_dir=`
- Note that `data_dir = nil` resets to auto-resolution (no longer uses `instance_variable_set`)

In the **Dry-Run Mode** section, update:
- `Thread.current[:fb_dry_run]` — note this symbol is intentionally unchanged (internal impl detail)

In the **Key Patterns** section, update:
- `Auth.data_dir=` seam description to mention `FRESHBOOKS_HOME` and platform-native defaults

- [ ] **Step 3: Update README if needed**

If README references `~/.fb`, add a note that `~/.fb` is the legacy path, new installs use a platform-native location, and `FRESHBOOKS_HOME` overrides it.

- [ ] **Step 4: Commit**

```bash
git add AGENTS.md README.md
git commit -m "docs: update AGENTS.md and README for FreshBooks::CLI rename and new config dir resolution"
```
