# frozen_string_literal: true

require "json"

RSpec.describe FB::Auth do
  # --- Config Loading ---

  describe ".load_config" do
    context "with valid config file" do
      Given {
        FB::Auth.save_config("client_id" => "abc", "client_secret" => "xyz")
      }
      When(:result) { FB::Auth.load_config }
      Then { result == { "client_id" => "abc", "client_secret" => "xyz" } }
    end

    context "with empty file" do
      Given { File.write(FB::Auth.config_path, "") }
      When(:result) { FB::Auth.load_config }
      Then { result.nil? }
    end

    context "with missing client_secret" do
      Given {
        FileUtils.mkdir_p(FB::Auth.data_dir)
        File.write(FB::Auth.config_path, JSON.generate("client_id" => "abc"))
      }
      When(:result) { FB::Auth.load_config }
      Then { result.nil? }
    end

    context "with no file" do
      When(:result) { FB::Auth.load_config }
      Then { result.nil? }
    end
  end

  # --- Config Saving ---

  describe ".save_config" do
    When { FB::Auth.save_config("client_id" => "id1", "client_secret" => "sec1") }
    Then { File.exist?(FB::Auth.config_path) }
    And {
      parsed = JSON.parse(File.read(FB::Auth.config_path))
      parsed == { "client_id" => "id1", "client_secret" => "sec1" }
    }
  end

  # --- Token Expiry ---

  describe ".token_expired?" do
    context "with future expiry" do
      Given(:tokens) { { "created_at" => Time.now.to_i, "expires_in" => 3600 } }
      Then { FB::Auth.token_expired?(tokens) == false }
    end

    context "with past expiry" do
      Given(:tokens) { { "created_at" => Time.now.to_i - 7200, "expires_in" => 3600 } }
      Then { FB::Auth.token_expired?(tokens) == true }
    end

    context "with nil tokens" do
      Then { FB::Auth.token_expired?(nil) == true }
    end
  end

  # --- Token Refresh ---

  describe ".refresh_token!" do
    Given(:config) { { "client_id" => "cid", "client_secret" => "csec" } }
    Given(:tokens) { { "refresh_token" => "old_refresh" } }

    context "when API returns new tokens" do
      Given {
        stub_request(:post, FB::Auth::TOKEN_URL)
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
      When(:result) { FB::Auth.refresh_token!(config, tokens) }
      Then { result["access_token"] == "new_access" }
      And  { result["refresh_token"] == "new_refresh" }
      And  { result["expires_in"] == 3600 }
      And  { result["created_at"].is_a?(Integer) }
      And  { File.exist?(FB::Auth.tokens_path) }
    end

    context "when API returns 401" do
      Given {
        stub_request(:post, FB::Auth::TOKEN_URL)
          .to_return(
            status: 401,
            headers: { "Content-Type" => "application/json" },
            body: { "error" => "invalid_grant" }.to_json
          )
      }
      When(:result) { FB::Auth.refresh_token!(config, tokens) }
      Then { result == Failure(SystemExit) }
    end
  end

  # --- Scope Checking ---

  describe ".check_scopes" do
    context "with all required scopes" do
      Given(:scope_string) { FB::Auth::REQUIRED_SCOPES.join(" ") }
      When(:result) { FB::Auth.check_scopes(scope_string) }
      Then { !result.is_a?(SystemExit) }
    end

    context "with nil scopes (API didn't return them)" do
      When(:result) { FB::Auth.check_scopes(nil) }
      Then { result.nil? }
    end

    context "with missing scopes" do
      Given(:scope_string) { "user:profile:read" }
      When(:result) { FB::Auth.check_scopes(scope_string) }
      Then { result == Failure(SystemExit) }
    end
  end

  # --- Defaults ---

  describe ".load_defaults" do
    context "with no file" do
      When(:result) { FB::Auth.load_defaults }
      Then { result == {} }
    end

    context "with valid file" do
      Given { FB::Auth.save_defaults("client_id" => 123) }
      When(:result) { FB::Auth.load_defaults }
      Then { result == { "client_id" => 123 } }
    end
  end

  describe ".save_defaults" do
    When { FB::Auth.save_defaults("project_id" => 42) }
    Then { File.exist?(FB::Auth.defaults_path) }
    And {
      JSON.parse(File.read(FB::Auth.defaults_path)) == { "project_id" => 42 }
    }
  end

  # --- Cache ---

  describe ".load_cache" do
    context "with no file" do
      When(:result) { FB::Auth.load_cache }
      Then { result == {} }
    end
  end

  describe ".save_cache" do
    When { FB::Auth.save_cache("updated_at" => 100) }
    Then {
      JSON.parse(File.read(FB::Auth.cache_path)) == { "updated_at" => 100 }
    }
  end
end
