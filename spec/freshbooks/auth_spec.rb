# frozen_string_literal: true

require "json"

RSpec.describe FreshBooks::CLI::Auth do
  # --- Config Loading ---

  describe ".load_config" do
    context "with credentials in ENV and business_id in config.json" do
      Given {
        ENV["FRESHBOOKS_CLIENT_ID"] = "abc"
        ENV["FRESHBOOKS_CLIENT_SECRET"] = "xyz"
        FileUtils.mkdir_p(FreshBooks::CLI::Auth.data_dir)
        File.write(FreshBooks::CLI::Auth.config_path, JSON.generate("business_id" => 99, "account_id" => "acc9"))
      }
      after {
        ENV.delete("FRESHBOOKS_CLIENT_ID")
        ENV.delete("FRESHBOOKS_CLIENT_SECRET")
      }
      When(:result) { FreshBooks::CLI::Auth.load_config }
      Then { result["client_id"] == "abc" }
      And  { result["client_secret"] == "xyz" }
      And  { result["business_id"] == 99 }
      And  { result["account_id"] == "acc9" }
    end

    context "with credentials in .env file" do
      Given {
        FileUtils.mkdir_p(FreshBooks::CLI::Auth.data_dir)
        File.write(File.join(FreshBooks::CLI::Auth.data_dir, ".env"), "FRESHBOOKS_CLIENT_ID=dotenv_id\nFRESHBOOKS_CLIENT_SECRET=dotenv_sec\n")
      }
      after {
        ENV.delete("FRESHBOOKS_CLIENT_ID")
        ENV.delete("FRESHBOOKS_CLIENT_SECRET")
      }
      When(:result) { FreshBooks::CLI::Auth.load_config }
      Then { result["client_id"] == "dotenv_id" }
      And  { result["client_secret"] == "dotenv_sec" }
    end

    context "with no credentials in ENV or .env" do
      Given {
        ENV.delete("FRESHBOOKS_CLIENT_ID")
        ENV.delete("FRESHBOOKS_CLIENT_SECRET")
      }
      When(:result) { FreshBooks::CLI::Auth.load_config }
      Then { result.nil? }
    end
  end

  # --- Config Saving ---

  describe ".save_config" do
    When { FreshBooks::CLI::Auth.save_config("client_id" => "id1", "client_secret" => "sec1", "business_id" => 5) }
    Then { File.exist?(FreshBooks::CLI::Auth.config_path) }
    And {
      parsed = JSON.parse(File.read(FreshBooks::CLI::Auth.config_path))
      parsed == { "business_id" => 5 }
    }
  end

  # --- Token Expiry ---

  describe ".token_expired?" do
    context "with future expiry" do
      Given(:tokens) { { "created_at" => Time.now.to_i, "expires_in" => 3600 } }
      Then { FreshBooks::CLI::Auth.token_expired?(tokens) == false }
    end

    context "with past expiry" do
      Given(:tokens) { { "created_at" => Time.now.to_i - 7200, "expires_in" => 3600 } }
      Then { FreshBooks::CLI::Auth.token_expired?(tokens) == true }
    end

    context "with nil tokens" do
      Then { FreshBooks::CLI::Auth.token_expired?(nil) == true }
    end
  end

  # --- Token Refresh ---

  describe ".refresh_token!" do
    Given(:config) { { "client_id" => "cid", "client_secret" => "csec" } }
    Given(:tokens) { { "refresh_token" => "old_refresh" } }

    context "when API returns new tokens" do
      Given {
        stub_request(:post, FreshBooks::CLI::Auth::TOKEN_URL)
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: {
              "access_token" => "new_access",
              "refresh_token" => "new_refresh",
              "expires_in" => 3600
            }.to_json
          )
      }
      When(:result) { FreshBooks::CLI::Auth.refresh_token!(config, tokens) }
      Then { result["access_token"] == "new_access" }
      And  { result["refresh_token"] == "new_refresh" }
      And  { result["expires_in"] == 3600 }
      And  { result["created_at"].is_a?(Integer) }
      And  { File.exist?(FreshBooks::CLI::Auth.tokens_path) }
    end

    context "when API returns 401" do
      Given {
        stub_request(:post, FreshBooks::CLI::Auth::TOKEN_URL)
          .to_return(
            status: 401,
            headers: { "Content-Type" => "application/json" },
            body: { "error" => "invalid_grant" }.to_json
          )
      }
      When(:result) { FreshBooks::CLI::Auth.refresh_token!(config, tokens) }
      Then { result == Failure(SystemExit) }
    end
  end

  # --- Scope Checking ---

  describe ".check_scopes" do
    context "with all required scopes" do
      Given(:scope_string) { FreshBooks::CLI::Auth::REQUIRED_SCOPES.join(" ") }
      When(:result) { FreshBooks::CLI::Auth.check_scopes(scope_string) }
      Then { !result.is_a?(SystemExit) }
    end

    context "with nil scopes (API didn't return them)" do
      When(:result) { FreshBooks::CLI::Auth.check_scopes(nil) }
      Then { result.nil? }
    end

    context "with missing scopes" do
      Given(:scope_string) { "user:profile:read" }
      When(:result) { FreshBooks::CLI::Auth.check_scopes(scope_string) }
      Then { result == Failure(SystemExit) }
    end
  end

  # --- Migrate Credentials from Config ---

  describe ".migrate_credentials_from_config" do
    let(:env_path) { File.join(FreshBooks::CLI::Auth.data_dir, ".env") }

    context "when config.json has client_id and client_secret" do
      Given {
        FileUtils.mkdir_p(FreshBooks::CLI::Auth.data_dir)
        File.write(FreshBooks::CLI::Auth.config_path, JSON.generate("client_id" => "old_id", "client_secret" => "old_sec", "business_id" => 42))
      }
      When { FreshBooks::CLI::Auth.migrate_credentials_from_config }
      Then { File.read(env_path).include?("FRESHBOOKS_CLIENT_ID=old_id") }
      And  { File.read(env_path).include?("FRESHBOOKS_CLIENT_SECRET=old_sec") }
      And  { !JSON.parse(File.read(FreshBooks::CLI::Auth.config_path)).key?("client_id") }
      And  { !JSON.parse(File.read(FreshBooks::CLI::Auth.config_path)).key?("client_secret") }
      And  { JSON.parse(File.read(FreshBooks::CLI::Auth.config_path))["business_id"] == 42 }
    end

    context "when .env already has the keys" do
      Given {
        FileUtils.mkdir_p(FreshBooks::CLI::Auth.data_dir)
        File.write(env_path, "FRESHBOOKS_CLIENT_ID=existing\nFRESHBOOKS_CLIENT_SECRET=existing_sec\n")
        File.write(FreshBooks::CLI::Auth.config_path, JSON.generate("client_id" => "old_id", "client_secret" => "old_sec"))
      }
      When { FreshBooks::CLI::Auth.migrate_credentials_from_config }
      Then { File.read(env_path) == "FRESHBOOKS_CLIENT_ID=existing\nFRESHBOOKS_CLIENT_SECRET=existing_sec\n" }
    end

    context "when config.json has no credentials" do
      Given {
        FileUtils.mkdir_p(FreshBooks::CLI::Auth.data_dir)
        File.write(FreshBooks::CLI::Auth.config_path, JSON.generate("business_id" => 7))
      }
      When { FreshBooks::CLI::Auth.migrate_credentials_from_config }
      Then { !File.exist?(env_path) }
    end

    context "when config.json does not exist" do
      When(:result) { FreshBooks::CLI::Auth.migrate_credentials_from_config }
      Then { result.nil? }
    end
  end

  # --- Write Credentials to .env ---

  describe ".write_credentials_to_env" do
    let(:env_path) { File.join(FreshBooks::CLI::Auth.data_dir, ".env") }

    context "when .env does not exist" do
      When { FreshBooks::CLI::Auth.write_credentials_to_env(env_path, "my_id", "my_secret") }
      Then { File.exist?(env_path) }
      And  { File.read(env_path).include?("FRESHBOOKS_CLIENT_ID=my_id") }
      And  { File.read(env_path).include?("FRESHBOOKS_CLIENT_SECRET=my_secret") }
    end

    context "when .env exists without the keys" do
      Given {
        FileUtils.mkdir_p(FreshBooks::CLI::Auth.data_dir)
        File.write(env_path, "OTHER_VAR=other\n")
      }
      When { FreshBooks::CLI::Auth.write_credentials_to_env(env_path, "appended_id", "appended_secret") }
      Then { File.read(env_path).include?("OTHER_VAR=other") }
      And  { File.read(env_path).include?("FRESHBOOKS_CLIENT_ID=appended_id") }
      And  { File.read(env_path).include?("FRESHBOOKS_CLIENT_SECRET=appended_secret") }
    end

    context "when .env exists with keys already present" do
      Given {
        FileUtils.mkdir_p(FreshBooks::CLI::Auth.data_dir)
        File.write(env_path, "FRESHBOOKS_CLIENT_ID=existing_id\nFRESHBOOKS_CLIENT_SECRET=existing_secret\n")
      }
      When { FreshBooks::CLI::Auth.write_credentials_to_env(env_path, "new_id", "new_secret") }
      Then { File.read(env_path) == "FRESHBOOKS_CLIENT_ID=existing_id\nFRESHBOOKS_CLIENT_SECRET=existing_secret\n" }
    end
  end

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
      When(:result) { FreshBooks::CLI::Auth.setup_config_from_args }
      Then { result == { "client_id" => "env_id", "client_secret" => "env_secret" } }
      And  { !File.exist?(FreshBooks::CLI::Auth.config_path) }
    end

    context "with .env file in data_dir" do
      Given {
        FileUtils.mkdir_p(FreshBooks::CLI::Auth.data_dir)
        File.write(File.join(FreshBooks::CLI::Auth.data_dir, ".env"), "FRESHBOOKS_CLIENT_ID=dotenv_id\nFRESHBOOKS_CLIENT_SECRET=dotenv_secret\n")
      }
      after {
        ENV.delete("FRESHBOOKS_CLIENT_ID")
        ENV.delete("FRESHBOOKS_CLIENT_SECRET")
      }
      When(:result) { FreshBooks::CLI::Auth.setup_config_from_args }
      Then { result == { "client_id" => "dotenv_id", "client_secret" => "dotenv_secret" } }
    end

    context "with missing FRESHBOOKS_CLIENT_ID" do
      Given {
        ENV.delete("FRESHBOOKS_CLIENT_ID")
        ENV["FRESHBOOKS_CLIENT_SECRET"] = "sec"
      }
      after { ENV.delete("FRESHBOOKS_CLIENT_SECRET") }
      When(:result) { FreshBooks::CLI::Auth.setup_config_from_args }
      Then { result == Failure(SystemExit) }
    end

    context "with missing FRESHBOOKS_CLIENT_SECRET" do
      Given {
        ENV["FRESHBOOKS_CLIENT_ID"] = "id"
        ENV.delete("FRESHBOOKS_CLIENT_SECRET")
      }
      after { ENV.delete("FRESHBOOKS_CLIENT_ID") }
      When(:result) { FreshBooks::CLI::Auth.setup_config_from_args }
      Then { result == Failure(SystemExit) }
    end

    context "with no env vars and no .env file" do
      Given {
        ENV.delete("FRESHBOOKS_CLIENT_ID")
        ENV.delete("FRESHBOOKS_CLIENT_SECRET")
      }
      When(:result) { FreshBooks::CLI::Auth.setup_config_from_args }
      Then { result == Failure(SystemExit) }
    end
  end

  # --- Interactive Setup with Masked Secret ---

  describe ".setup_config" do
    let(:env_path) { File.join(FreshBooks::CLI::Auth.data_dir, ".env") }

    context "writes credentials to ~/.fb/.env" do
      Given {
        allow($stdin).to receive(:gets).and_return("my_client_id\n")
        console_double = instance_double(IO)
        allow(IO).to receive(:console).and_return(console_double)
        allow(console_double).to receive(:getpass).with("").and_return("my_secret")
      }
      after {
        ENV.delete("FRESHBOOKS_CLIENT_ID")
        ENV.delete("FRESHBOOKS_CLIENT_SECRET")
      }
      When { capture_stdout { FreshBooks::CLI::Auth.setup_config } }
      Then { File.exist?(env_path) }
      And  { File.read(env_path).include?("FRESHBOOKS_CLIENT_ID=my_client_id") }
      And  { File.read(env_path).include?("FRESHBOOKS_CLIENT_SECRET=my_secret") }
    end

    context "prompts to overwrite when credentials already exist" do
      Given {
        FileUtils.mkdir_p(FreshBooks::CLI::Auth.data_dir)
        File.write(env_path, "FRESHBOOKS_CLIENT_ID=old_id\nFRESHBOOKS_CLIENT_SECRET=old_sec\n")
        allow($stdin).to receive(:gets).and_return("new_id\n", "y\n")
        console_double = instance_double(IO)
        allow(IO).to receive(:console).and_return(console_double)
        allow(console_double).to receive(:getpass).with("").and_return("new_sec")
      }
      When { capture_stdout { FreshBooks::CLI::Auth.setup_config } }
      Then { File.read(env_path).include?("FRESHBOOKS_CLIENT_ID=new_id") }
      And  { File.read(env_path).include?("FRESHBOOKS_CLIENT_SECRET=new_sec") }
    end
  end

  # --- Authorize URL ---

  describe ".authorize_url" do
    Given(:config) { { "client_id" => "test_cid", "client_secret" => "sec" } }
    When(:result) { FreshBooks::CLI::Auth.authorize_url(config) }
    Then { result.include?("auth.freshbooks.com/oauth/authorize") }
    And  { result.include?("client_id=test_cid") }
  end

  # --- Extract Code From URL ---

  describe ".extract_code_from_url" do
    context "with valid redirect URL" do
      When(:result) { FreshBooks::CLI::Auth.extract_code_from_url("https://localhost?code=abc123") }
      Then { result == "abc123" }
    end

    context "with no code parameter" do
      When(:result) { FreshBooks::CLI::Auth.extract_code_from_url("https://localhost?error=denied") }
      Then { result.nil? }
    end
  end

  # --- Auth Status ---

  describe ".auth_status" do
    context "with no config or tokens" do
      When(:result) { FreshBooks::CLI::Auth.auth_status }
      Then { result["config_exists"] == false }
      And  { result["tokens_exist"] == false }
    end

    context "with config and tokens" do
      Given {
        ENV["FRESHBOOKS_CLIENT_ID"] = "id"
        ENV["FRESHBOOKS_CLIENT_SECRET"] = "sec"
        FreshBooks::CLI::Auth.save_config("business_id" => 123, "account_id" => "acc")
        FreshBooks::CLI::Auth.save_tokens("access_token" => "tok", "refresh_token" => "ref", "expires_in" => 3600, "created_at" => Time.now.to_i)
      }
      after {
        ENV.delete("FRESHBOOKS_CLIENT_ID")
        ENV.delete("FRESHBOOKS_CLIENT_SECRET")
      }
      When(:result) { FreshBooks::CLI::Auth.auth_status }
      Then { result["config_exists"] == true }
      And  { result["tokens_exist"] == true }
      And  { result["tokens_expired"] == false }
      And  { result["business_id"] == 123 }
    end
  end

  # --- Fetch Businesses ---

  describe ".fetch_businesses" do
    Given {
      stub_request(:get, FreshBooks::CLI::Auth::ME_URL)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "response" => {
              "business_memberships" => [
                { "business" => { "id" => 1, "name" => "Biz One", "account_id" => "acc1" } },
                { "business" => { "id" => 2, "name" => "Biz Two", "account_id" => "acc2" } }
              ]
            }
          }.to_json
        )
    }
    When(:result) { FreshBooks::CLI::Auth.fetch_businesses("token") }
    Then { result.length == 2 }
    And  { result.first.dig("business", "name") == "Biz One" }
  end

  # --- Select Business ---

  describe ".select_business" do
    let(:businesses) {
      [
        { "business" => { "id" => 1, "name" => "Biz One", "account_id" => "acc1" } },
        { "business" => { "id" => 2, "name" => "Biz Two", "account_id" => "acc2" } }
      ]
    }

    context "with valid business_id" do
      Given {
        ENV["FRESHBOOKS_CLIENT_ID"] = "id"
        ENV["FRESHBOOKS_CLIENT_SECRET"] = "sec"
      }
      after {
        ENV.delete("FRESHBOOKS_CLIENT_ID")
        ENV.delete("FRESHBOOKS_CLIENT_SECRET")
      }
      When(:result) {
        config = FreshBooks::CLI::Auth.load_config
        FreshBooks::CLI::Auth.select_business(config, 2, businesses)
      }
      Then { result["business_id"] == 2 }
      And  { result["account_id"] == "acc2" }
    end

    context "with invalid business_id" do
      Given {
        ENV["FRESHBOOKS_CLIENT_ID"] = "id"
        ENV["FRESHBOOKS_CLIENT_SECRET"] = "sec"
      }
      after {
        ENV.delete("FRESHBOOKS_CLIENT_ID")
        ENV.delete("FRESHBOOKS_CLIENT_SECRET")
      }
      When(:result) {
        config = FreshBooks::CLI::Auth.load_config
        FreshBooks::CLI::Auth.select_business(config, 999, businesses)
      }
      Then { result == Failure(SystemExit) }
    end
  end

  # --- Defaults ---

  describe ".load_defaults" do
    context "with no file" do
      When(:result) { FreshBooks::CLI::Auth.load_defaults }
      Then { result == {} }
    end

    context "with valid file" do
      Given { FreshBooks::CLI::Auth.save_defaults("client_id" => 123) }
      When(:result) { FreshBooks::CLI::Auth.load_defaults }
      Then { result == { "client_id" => 123 } }
    end
  end

  describe ".save_defaults" do
    When { FreshBooks::CLI::Auth.save_defaults("project_id" => 42) }
    Then { File.exist?(FreshBooks::CLI::Auth.defaults_path) }
    And {
      JSON.parse(File.read(FreshBooks::CLI::Auth.defaults_path)) == { "project_id" => 42 }
    }
  end

  # --- Cache ---

  describe ".load_cache" do
    context "with no file" do
      When(:result) { FreshBooks::CLI::Auth.load_cache }
      Then { result == {} }
    end
  end

  describe ".save_cache" do
    When { FreshBooks::CLI::Auth.save_cache("updated_at" => 100) }
    Then {
      JSON.parse(File.read(FreshBooks::CLI::Auth.cache_path)) == { "updated_at" => 100 }
    }
  end

  # --- Dry-run mode ---

  describe ".valid_access_token in dry-run" do
    around do |example|
      Thread.current[:fb_dry_run] = true
      example.run
    ensure
      Thread.current[:fb_dry_run] = false
    end

    context "with no saved tokens" do
      When(:result) { FreshBooks::CLI::Auth.valid_access_token }
      Then { result == "dry-run-token" }
    end

    context "with a valid saved token" do
      Given {
        FreshBooks::CLI::Auth.save_tokens({
          "access_token" => "real-token-123",
          "refresh_token" => "refresh-abc",
          "expires_in" => 3600,
          "created_at" => Time.now.to_i
        })
      }
      When(:result) { FreshBooks::CLI::Auth.valid_access_token }
      Then { result == "real-token-123" }
    end
  end

  describe ".require_config in dry-run with existing config" do
    around do |example|
      Thread.current[:fb_dry_run] = true
      example.run
    ensure
      Thread.current[:fb_dry_run] = false
    end

    Given {
      FreshBooks::CLI::Auth.save_config("business_id" => 99, "account_id" => "acc1")
    }
    When(:result) { FreshBooks::CLI::Auth.require_config }
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

    When(:result) { FreshBooks::CLI::Auth.require_config }
    Then { result["business_id"] == "0" }
    And  { result["account_id"] == "0" }
  end

  # --- Data Directory Resolution ---

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
end

def capture_stdout
  original = $stdout
  $stdout = StringIO.new
  yield
  $stdout.string
ensure
  $stdout = original
end
