# frozen_string_literal: true

require "json"
require "date"

RSpec.describe FB::Cli do
  let(:access_token) { "test_token" }
  let(:config) {
    { "client_id" => "cid", "client_secret" => "csec",
      "business_id" => 12345, "account_id" => "acc99" }
  }

  before do
    allow(FB::Auth).to receive(:valid_access_token).and_return(access_token)
    allow(FB::Auth).to receive(:require_config).and_return(config)
  end

  # --- help --format json ---

  describe "help --format json" do
    When(:output) {
      capture_stdout { FB::Cli.start(["help", "--format", "json"]) }
    }
    Then {
      json = JSON.parse(output)
      json["required_scopes"].is_a?(Array) &&
        json["required_scopes"].length == 6 &&
        json["commands"].is_a?(Hash) &&
        json["commands"].key?("log") &&
        json["commands"].key?("entries")
    }
  end

  # --- entries date logic ---

  describe "entries" do
    let(:time_entries_url) { %r{api\.freshbooks\.com/timetracking/business/12345/time_entries} }
    let(:clients_url) { %r{api\.freshbooks\.com/accounting/account/acc99/users/clients} }
    let(:projects_url) { %r{api\.freshbooks\.com/projects/business/12345/projects} }

    before do
      stub_request(:get, clients_url)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "result" => { "clients" => [], "meta" => { "pages" => 1 } } }.to_json
        )
      stub_request(:get, projects_url)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "result" => { "projects" => [], "meta" => { "pages" => 1 } } }.to_json
        )
    end

    context "with --from and --to" do
      Given {
        stub_request(:get, time_entries_url)
          .with(query: hash_including(
            "started_from" => "2024-01-15T00:00:00Z",
            "started_to" => "2024-02-15T23:59:59Z"
          ))
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { "result" => { "time_entries" => [], "meta" => { "pages" => 1 } } }.to_json
          )
      }
      When {
        capture_stdout { FB::Cli.start(["entries", "--from", "2024-01-15", "--to", "2024-02-15"]) }
      }
      Then {
        assert_requested(:get, time_entries_url,
          query: hash_including(
            "started_from" => "2024-01-15T00:00:00Z",
            "started_to" => "2024-02-15T23:59:59Z"
          ))
        true
      }
    end

    context "with no flags (defaults to current month)" do
      Given {
        today = Date.today
        first = Date.new(today.year, today.month, 1).to_s
        last = Date.new(today.year, today.month, -1).to_s

        stub_request(:get, time_entries_url)
          .with(query: hash_including(
            "started_from" => "#{first}T00:00:00Z",
            "started_to" => "#{last}T23:59:59Z"
          ))
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { "result" => { "time_entries" => [], "meta" => { "pages" => 1 } } }.to_json
          )
      }
      When {
        capture_stdout { FB::Cli.start(["entries"]) }
      }
      Then {
        today = Date.today
        first = Date.new(today.year, today.month, 1).to_s
        last = Date.new(today.year, today.month, -1).to_s
        assert_requested(:get, time_entries_url,
          query: hash_including(
            "started_from" => "#{first}T00:00:00Z",
            "started_to" => "#{last}T23:59:59Z"
          ))
        true
      }
    end
  end

  # --- display_name ---

  describe "#display_name (via entries table output)" do
    it "returns organization when present" do
      cli = FB::Cli.new
      result = cli.send(:display_name, { "organization" => "Acme", "fname" => "J", "lname" => "D" })
      expect(result).to eq("Acme")
    end

    it "returns fname lname when organization is empty" do
      cli = FB::Cli.new
      result = cli.send(:display_name, { "organization" => "", "fname" => "Jane", "lname" => "Doe" })
      expect(result).to eq("Jane Doe")
    end

    it "returns fname lname when organization is nil" do
      cli = FB::Cli.new
      result = cli.send(:display_name, { "organization" => nil, "fname" => "Jane", "lname" => "Doe" })
      expect(result).to eq("Jane Doe")
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
