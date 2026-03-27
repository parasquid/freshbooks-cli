# Secure Credential Input Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove insecure CLI flags for OAuth credentials and replace with environment variables (via dotenv) and masked interactive input.

**Architecture:** Two independent changes to existing credential paths: (1) non-interactive reads from ENV with dotenv loading from `~/.fb/.env` or `./.env`, (2) interactive masks the client secret via `IO.console.getpass`. CLI flags `--client-id`/`--client-secret` are removed entirely.

**Tech Stack:** Ruby, Thor, dotenv gem, io/console stdlib

---

### Task 0: Update GitHub issue with design and plan

- [ ] **Step 1: Update issue #4 with the full design spec and implementation plan**

Update the body of GitHub issue #4 to include the full contents of both the design spec and this plan file.

Run:
```bash
gh issue edit 4 --body "$(cat docs/plans/2026-03-27-secure-credential-input-design.md; echo -e '\n\n---\n\n'; cat docs/plans/2026-03-27-secure-credential-input-plan.md)"
```

---

### Task 1: Add dotenv dependency

**Files:**
- Modify: `fb.gemspec:26-27`
- Modify: `lib/fb/auth.rb:1-6`

- [ ] **Step 1: Add dotenv to gemspec**

In `fb.gemspec`, add the dotenv dependency after the httparty line:

```ruby
  s.add_dependency "thor", "~> 1.3"
  s.add_dependency "httparty", ">= 0.24", "< 1.0"
  s.add_dependency "dotenv", "~> 3.1"
```

- [ ] **Step 2: Require dotenv in auth.rb**

In `lib/fb/auth.rb`, add `require "dotenv"` after the existing requires:

```ruby
require "httparty"
require "json"
require "uri"
require "fileutils"
require "dotenv"
```

- [ ] **Step 3: Install the gem and verify**

Run: `bundle install` or `gem install dotenv`
Expected: dotenv installs successfully

- [ ] **Step 4: Commit**

```bash
git add fb.gemspec lib/fb/auth.rb
git commit -m "Add dotenv dependency for secure credential loading"
```

---

### Task 2: Add load_dotenv method and update setup_config_from_args

**Files:**
- Modify: `lib/fb/auth.rb:97-104`
- Test: `spec/fb/auth_spec.rb`

- [ ] **Step 1: Write failing tests for env var credential loading**

Add these test contexts to `spec/fb/auth_spec.rb`, replacing the existing `.setup_config_from_args` describe block:

```ruby
  # --- Setup Config From Args (env vars) ---

  describe ".setup_config_from_args" do
    context "with env vars set" do
      Given {
        ENV["FRESHBOOKS_CLIENT_ID"] = "env_id"
        ENV["FRESHBOOKS_CLIENT_SECRET"] = "env_secret"
      }
      after {
        ENV.delete("FRESHBOOKS_CLIENT_ID")
        ENV.delete("FRESHBOOKS_CLIENT_SECRET")
      }
      When(:result) { FB::Auth.setup_config_from_args }
      Then { result == { "client_id" => "env_id", "client_secret" => "env_secret" } }
      And  { File.exist?(FB::Auth.config_path) }
    end

    context "with .env file in data_dir" do
      Given {
        FileUtils.mkdir_p(FB::Auth.data_dir)
        File.write(File.join(FB::Auth.data_dir, ".env"), "FRESHBOOKS_CLIENT_ID=dotenv_id\nFRESHBOOKS_CLIENT_SECRET=dotenv_secret\n")
      }
      after {
        ENV.delete("FRESHBOOKS_CLIENT_ID")
        ENV.delete("FRESHBOOKS_CLIENT_SECRET")
      }
      When(:result) { FB::Auth.setup_config_from_args }
      Then { result == { "client_id" => "dotenv_id", "client_secret" => "dotenv_secret" } }
    end

    context "with missing FRESHBOOKS_CLIENT_ID" do
      Given {
        ENV.delete("FRESHBOOKS_CLIENT_ID")
        ENV["FRESHBOOKS_CLIENT_SECRET"] = "sec"
      }
      after { ENV.delete("FRESHBOOKS_CLIENT_SECRET") }
      When(:result) { FB::Auth.setup_config_from_args }
      Then { result == Failure(SystemExit) }
    end

    context "with missing FRESHBOOKS_CLIENT_SECRET" do
      Given {
        ENV["FRESHBOOKS_CLIENT_ID"] = "id"
        ENV.delete("FRESHBOOKS_CLIENT_SECRET")
      }
      after { ENV.delete("FRESHBOOKS_CLIENT_ID") }
      When(:result) { FB::Auth.setup_config_from_args }
      Then { result == Failure(SystemExit) }
    end

    context "with no env vars and no .env file" do
      Given {
        ENV.delete("FRESHBOOKS_CLIENT_ID")
        ENV.delete("FRESHBOOKS_CLIENT_SECRET")
      }
      When(:result) { FB::Auth.setup_config_from_args }
      Then { result == Failure(SystemExit) }
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `docker compose run --rm --entrypoint rspec fb spec/fb/auth_spec.rb`
Expected: New tests fail (wrong number of arguments or method not found)

- [ ] **Step 3: Add load_dotenv method and update setup_config_from_args**

In `lib/fb/auth.rb`, add the `load_dotenv` method and replace `setup_config_from_args`:

```ruby
      def load_dotenv
        dot_env_paths = [
          File.join(data_dir, ".env"),
          File.join(Dir.pwd, ".env")
        ].select { |p| File.exist?(p) }
        Dotenv.load(*dot_env_paths) unless dot_env_paths.empty?
      end

      def setup_config_from_args
        load_dotenv

        client_id = ENV["FRESHBOOKS_CLIENT_ID"]
        client_secret = ENV["FRESHBOOKS_CLIENT_SECRET"]

        if client_id.nil? || client_id.strip.empty?
          abort("Missing FRESHBOOKS_CLIENT_ID. Set it via:\n  export FRESHBOOKS_CLIENT_ID=your_id\n  or add it to ~/.fb/.env")
        end

        if client_secret.nil? || client_secret.strip.empty?
          abort("Missing FRESHBOOKS_CLIENT_SECRET. Set it via:\n  export FRESHBOOKS_CLIENT_SECRET=your_secret\n  or add it to ~/.fb/.env")
        end

        config = { "client_id" => client_id.strip, "client_secret" => client_secret.strip }
        save_config(config)
        config
      end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `docker compose run --rm --entrypoint rspec fb spec/fb/auth_spec.rb`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add lib/fb/auth.rb spec/fb/auth_spec.rb
git commit -m "Replace CLI flag args with env var credential loading via dotenv"
```

---

### Task 3: Mask client secret in interactive setup

**Files:**
- Modify: `lib/fb/auth.rb:70-95`
- Test: `spec/fb/auth_spec.rb`

- [ ] **Step 1: Write failing test for masked input**

Add to `spec/fb/auth_spec.rb`:

```ruby
  # --- Interactive Setup with Masked Secret ---

  describe ".setup_config" do
    context "masks client secret input" do
      Given {
        allow($stdin).to receive(:gets).and_return("my_client_id\n")
        console_double = instance_double(IO)
        allow(IO).to receive(:console).and_return(console_double)
        allow(console_double).to receive(:getpass).with("").and_return("my_secret")
      }
      When(:result) {
        capture_stdout { FB::Auth.setup_config }
      }
      Then {
        config = FB::Auth.load_config
        config["client_id"] == "my_client_id" && config["client_secret"] == "my_secret"
      }
    end
  end
```

Also add the `capture_stdout` helper at the bottom of the file if not already present:

```ruby
def capture_stdout
  original = $stdout
  $stdout = StringIO.new
  yield
  $stdout.string
ensure
  $stdout = original
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `docker compose run --rm --entrypoint rspec fb spec/fb/auth_spec.rb`
Expected: Fails because `setup_config` still uses `$stdin.gets` for the secret

- [ ] **Step 3: Update setup_config to use getpass**

In `lib/fb/auth.rb`, replace the `setup_config` method. Change the client secret input from `$stdin.gets` to `IO.console.getpass`:

```ruby
      def setup_config
        puts "Welcome to FreshBooks CLI setup!\n\n"
        puts "You need a FreshBooks Developer App. Create one at:"
        puts "  https://my.freshbooks.com/#/developer\n\n"
        puts "Set the redirect URI to: #{REDIRECT_URI}\n\n"
        puts "Required scopes:"
        puts "  user:profile:read          (enabled by default)"
        puts "  user:clients:read"
        puts "  user:projects:read"
        puts "  user:billable_items:read"
        puts "  user:time_entries:read"
        puts "  user:time_entries:write\n\n"

        print "Client ID: "
        client_id = $stdin.gets&.strip
        abort("Aborted.") if client_id.nil? || client_id.empty?

        print "Client Secret: "
        client_secret = IO.console.getpass("")
        abort("Aborted.") if client_secret.nil? || client_secret.empty?

        config = { "client_id" => client_id, "client_secret" => client_secret }
        save_config(config)
        puts "\nConfig saved to #{config_path}"
        config
      end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `docker compose run --rm --entrypoint rspec fb spec/fb/auth_spec.rb`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add lib/fb/auth.rb spec/fb/auth_spec.rb
git commit -m "Mask client secret during interactive setup with IO.console.getpass"
```

---

### Task 4: Remove CLI flags and update cli.rb

**Files:**
- Modify: `lib/fb/cli.rb:34-49,59,105`
- Test: `spec/fb/cli_spec.rb`

- [ ] **Step 1: Update CLI tests for auth setup**

In `spec/fb/cli_spec.rb`, replace the auth setup test contexts:

```ruby
  # --- auth subcommands ---

  describe "auth" do
    context "setup with env vars" do
      Given {
        ENV["FRESHBOOKS_CLIENT_ID"] = "test_id"
        ENV["FRESHBOOKS_CLIENT_SECRET"] = "test_sec"
      }
      after {
        ENV.delete("FRESHBOOKS_CLIENT_ID")
        ENV.delete("FRESHBOOKS_CLIENT_SECRET")
      }
      When(:output) {
        capture_stdout { FB::Cli.start(["auth", "setup"]) }
      }
      Then { output.include?("Config saved") }
      And  {
        config = FB::Auth.load_config
        config["client_id"] == "test_id" && config["client_secret"] == "test_sec"
      }
    end

    context "setup with --format json" do
      Given {
        ENV["FRESHBOOKS_CLIENT_ID"] = "test_id"
        ENV["FRESHBOOKS_CLIENT_SECRET"] = "test_sec"
      }
      after {
        ENV.delete("FRESHBOOKS_CLIENT_ID")
        ENV.delete("FRESHBOOKS_CLIENT_SECRET")
      }
      When(:output) {
        capture_stdout { FB::Cli.start(["auth", "setup", "--format", "json"]) }
      }
      Then {
        json = JSON.parse(output)
        json["status"] == "saved"
      }
    end

    context "setup missing env vars aborts" do
      Given {
        ENV.delete("FRESHBOOKS_CLIENT_ID")
        ENV.delete("FRESHBOOKS_CLIENT_SECRET")
      }
      When(:result) {
        capture_stdout { FB::Cli.start(["auth", "setup"]) }
      }
      Then { result == Failure(SystemExit) }
    end
```

Keep the remaining auth test contexts (url, callback, status, non-interactive) unchanged, but update the abort messages in the "url without config aborts" test if needed.

- [ ] **Step 2: Run tests to verify they fail**

Run: `docker compose run --rm --entrypoint rspec fb spec/fb/cli_spec.rb`
Expected: Tests fail because CLI still expects `--client-id`/`--client-secret` flags

- [ ] **Step 3: Remove CLI flags and update auth command**

In `lib/fb/cli.rb`, remove the `method_option` lines and update the `auth` method:

```ruby
    desc "auth [SUBCOMMAND] [ARGS]", "Authenticate with FreshBooks via OAuth2 (subcommands: setup, url, callback, status)"
    def auth(subcommand = nil, *args)
      case subcommand
      when "setup"
        config = Auth.setup_config_from_args
        if options[:format] == "json"
          puts JSON.pretty_generate({ "config_path" => Auth.config_path, "status" => "saved" })
        else
          puts "Config saved to #{Auth.config_path}"
        end
```

Update the abort messages in the `url` and `callback` cases:

```ruby
      when "url"
        config = Auth.load_config
        abort("No config found. Run: fb auth setup (set FRESHBOOKS_CLIENT_ID and FRESHBOOKS_CLIENT_SECRET first)") unless config
```

```ruby
      when "callback"
        config = Auth.load_config
        abort("No config found. Run: fb auth setup (set FRESHBOOKS_CLIENT_ID and FRESHBOOKS_CLIENT_SECRET first)") unless config
```

- [ ] **Step 4: Update help text in the help command**

In `lib/fb/cli.rb`, find the `help` method's auth section and update it. Replace the setup subcommand description and flags:

```ruby
            subcommands: {
              "setup" => "Save OAuth credentials from env vars: FRESHBOOKS_CLIENT_ID, FRESHBOOKS_CLIENT_SECRET (or ~/.fb/.env)",
              "url" => "Print the OAuth authorization URL",
              "callback" => "Exchange OAuth code: fb auth callback REDIRECT_URL",
              "status" => "Show current auth state (config, tokens, business)"
            },
            flags: {}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `docker compose run --rm --entrypoint rspec fb spec/fb/cli_spec.rb`
Expected: All tests pass

- [ ] **Step 6: Run full test suite**

Run: `docker compose run --rm --entrypoint rspec fb`
Expected: All tests pass

- [ ] **Step 7: Commit**

```bash
git add lib/fb/cli.rb spec/fb/cli_spec.rb
git commit -m "Remove --client-id/--client-secret CLI flags, read credentials from env vars"
```

---

### Task 5: Add .env.example and update .gitignore

**Files:**
- Create: `.env.example`
- Modify: `.gitignore`

- [ ] **Step 1: Create .env.example**

```
# FreshBooks CLI credentials
# Copy to ~/.fb/.env (recommended) or ./.env and fill in your values.
# Get these from https://my.freshbooks.com/#/developer
FRESHBOOKS_CLIENT_ID=your_client_id_here
FRESHBOOKS_CLIENT_SECRET=your_client_secret_here
```

- [ ] **Step 2: Add .env to .gitignore**

Add `.env` to the end of `.gitignore`:

```
*.gem
Gemfile.lock
.fb/
.claude/
.env
```

- [ ] **Step 3: Commit**

```bash
git add .env.example .gitignore
git commit -m "Add .env.example template and gitignore .env files"
```

---

### Task 6: Update README documentation

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update the auth setup section in README**

Find the `### \`fb auth\`` section and the agent auth flow section. Replace references to `--client-id`/`--client-secret` with env var instructions.

In the `### \`fb auth\`` subcommands section, replace:

```markdown
```bash
# Save OAuth credentials
fb auth setup --client-id YOUR_ID --client-secret YOUR_SECRET
```
```

With:

```markdown
```bash
# Save OAuth credentials (set env vars first)
export FRESHBOOKS_CLIENT_ID=YOUR_ID
export FRESHBOOKS_CLIENT_SECRET=YOUR_SECRET
fb auth setup

# Or use a .env file (recommended)
cp .env.example ~/.fb/.env   # edit with your credentials
fb auth setup
```
```

- [ ] **Step 2: Update the agent auth flow section**

In the "Full agent auth flow" section, replace:

```markdown
```bash
# 1. Save credentials
fb auth setup --client-id YOUR_ID --client-secret YOUR_SECRET
```
```

With:

```markdown
```bash
# 1. Save credentials (via env vars or ~/.fb/.env)
export FRESHBOOKS_CLIENT_ID=YOUR_ID
export FRESHBOOKS_CLIENT_SECRET=YOUR_SECRET
fb auth setup
```
```

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "Update README: document env var and .env credential setup"
```

---

### Task 7: Update AGENTS.md auth flow documentation

**Files:**
- Modify: `AGENTS.md`

- [ ] **Step 1: Update auth flow section**

In `AGENTS.md`, update the Auth Flow section. Replace:

```markdown
- `fb auth setup --client-id ID --client-secret SECRET` — saves config
```

With:

```markdown
- `fb auth setup` — saves config from `FRESHBOOKS_CLIENT_ID` and `FRESHBOOKS_CLIENT_SECRET` env vars (or `~/.fb/.env`)
```

- [ ] **Step 2: Commit**

```bash
git add AGENTS.md
git commit -m "Update AGENTS.md: document env var auth setup"
```

---

### Task 8: Final verification

- [ ] **Step 1: Run full test suite**

Run: `docker compose run --rm --entrypoint rspec fb`
Expected: All tests pass, no failures

- [ ] **Step 2: Build gem to verify gemspec**

Run: `gem build fb.gemspec`
Expected: Gem builds successfully with dotenv dependency

- [ ] **Step 3: Manual smoke test (optional)**

```bash
# Test env var path
FRESHBOOKS_CLIENT_ID=test FRESHBOOKS_CLIENT_SECRET=test fb auth setup
fb auth status

# Test .env file path
echo "FRESHBOOKS_CLIENT_ID=test2\nFRESHBOOKS_CLIENT_SECRET=test2" > ~/.fb/.env
fb auth setup
fb auth status
```
