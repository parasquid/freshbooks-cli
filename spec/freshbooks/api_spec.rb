# frozen_string_literal: true

require "json"

RSpec.describe FreshBooks::CLI::Api do
  let(:access_token) { "test_token_123" }
  let(:config) {
    { "client_id" => "cid", "client_secret" => "csec",
      "business_id" => 12345, "account_id" => "acc99" }
  }

  before do
    allow(FreshBooks::CLI::Auth).to receive(:valid_access_token).and_return(access_token)
    allow(FreshBooks::CLI::Auth).to receive(:require_config).and_return(config)
  end

  # --- fetch_time_entries URL params ---

  describe ".fetch_time_entries" do
    Given {
      stub_request(:get, %r{api\.freshbooks\.com/timetracking/business/12345/time_entries})
        .with(query: hash_including("started_from" => "2024-03-01T00:00:00Z",
                                    "started_to" => "2024-03-31T23:59:59Z"))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "result" => {
              "time_entries" => [{ "id" => 1, "duration" => 3600 }],
              "meta" => { "pages" => 1, "page" => 1 }
            }
          }.to_json
        )
    }
    When(:result) {
      FreshBooks::CLI::Api.fetch_time_entries(started_from: "2024-03-01", started_to: "2024-03-31")
    }
    Then { result.length == 1 }
    And  { result.first["id"] == 1 }
  end

  # --- Pagination ---

  describe ".fetch_all_pages" do
    context "with 2-page response" do
      Given {
        url = "#{FreshBooks::CLI::Api::BASE}/timetracking/business/12345/time_entries"
        stub_request(:get, url)
          .with(query: hash_including("page" => "1"))
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: {
              "result" => {
                "time_entries" => [{ "id" => 1 }, { "id" => 2 }],
                "meta" => { "pages" => 2, "page" => 1 }
              }
            }.to_json
          )

        stub_request(:get, url)
          .with(query: hash_including("page" => "2"))
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: {
              "result" => {
                "time_entries" => [{ "id" => 3 }],
                "meta" => { "pages" => 2, "page" => 2 }
              }
            }.to_json
          )
      }
      When(:result) {
        FreshBooks::CLI::Api.fetch_all_pages(
          "#{FreshBooks::CLI::Api::BASE}/timetracking/business/12345/time_entries",
          "time_entries"
        )
      }
      Then { result.length == 3 }
      And  { result.map { |e| e["id"] } == [1, 2, 3] }
    end
  end

  # --- build_name_maps caching ---

  describe ".build_name_maps" do
    let(:clients_url) { %r{api\.freshbooks\.com/accounting/account/acc99/users/clients} }
    let(:projects_url) { %r{api\.freshbooks\.com/projects/business/12345/projects} }
    let(:services_url) { %r{api\.freshbooks\.com/comments/business/12345/services} }

    context "with stale or no cache" do
      Given {
        stub_request(:get, clients_url)
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: {
              "result" => {
                "clients" => [{ "id" => 10, "organization" => "Acme Corp", "fname" => "J", "lname" => "D" }],
                "meta" => { "pages" => 1, "page" => 1 }
              }
            }.to_json
          )

        stub_request(:get, projects_url)
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: {
              "result" => {
                "projects" => [{ "id" => 20, "title" => "Website Redesign" }],
                "meta" => { "pages" => 1, "page" => 1 }
              }
            }.to_json
          )

        stub_request(:get, %r{api\.freshbooks\.com/comments/business/12345/services})
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { "result" => { "services" => { "30" => { "id" => 30, "name" => "Dev" } } } }.to_json
          )
      }
      When(:result) { FreshBooks::CLI::Api.build_name_maps }
      Then { result[:clients]["10"] == "Acme Corp" }
      And  { result[:projects]["20"] == "Website Redesign" }
      And  { result[:services]["30"] == "Dev" }
    end

    context "with fresh cache (< 10 min old)" do
      Given {
        FreshBooks::CLI::Auth.save_cache(
          "updated_at" => Time.now.to_i - 60,
          "clients" => { "10" => "Cached Client" },
          "projects" => { "20" => "Cached Project" }
        )
      }
      When(:result) { FreshBooks::CLI::Api.build_name_maps }
      Then { result[:clients]["10"] == "Cached Client" }
      And  { result[:projects]["20"] == "Cached Project" }
      And  {
        assert_not_requested(:get, %r{api\.freshbooks\.com})
        true
      }
    end
  end

  # --- fetch_time_entry ---

  describe ".fetch_time_entry" do
    Given {
      stub_request(:get, %r{api\.freshbooks\.com/timetracking/business/12345/time_entries/999})
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "result" => {
              "time_entry" => { "id" => 999, "duration" => 7200, "note" => "Test" }
            }
          }.to_json
        )
    }
    When(:result) { FreshBooks::CLI::Api.fetch_time_entry(999) }
    Then { result["id"] == 999 }
    And  { result["duration"] == 7200 }
  end

  # --- update_time_entry ---

  describe ".update_time_entry" do
    Given {
      stub_request(:put, %r{api\.freshbooks\.com/timetracking/business/12345/time_entries/999})
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "result" => {
              "time_entry" => { "id" => 999, "duration" => 5400, "note" => "Updated" }
            }
          }.to_json
        )
    }
    When(:result) { FreshBooks::CLI::Api.update_time_entry(999, { "duration" => 5400, "note" => "Updated" }) }
    Then { result["result"]["time_entry"]["note"] == "Updated" }
  end

  # --- delete_time_entry ---

  describe ".delete_time_entry" do
    Given {
      stub_request(:delete, %r{api\.freshbooks\.com/timetracking/business/12345/time_entries/999})
        .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: "")
    }
    When(:result) { FreshBooks::CLI::Api.delete_time_entry(999) }
    Then { result == true }
  end

  # --- caching ---

  describe "caching" do
    let(:clients_url) { %r{api\.freshbooks\.com/accounting/account/acc99/users/clients} }

    context "fetch_clients returns cached data when fresh" do
      Given {
        FreshBooks::CLI::Auth.save_cache(
          "updated_at" => Time.now.to_i - 60,
          "clients_data" => [{ "id" => 10, "organization" => "Cached" }]
        )
      }
      When(:result) { FreshBooks::CLI::Api.fetch_clients }
      Then { result.first["organization"] == "Cached" }
      And  {
        assert_not_requested(:get, clients_url)
        true
      }
    end

    context "fetch_clients hits API when force: true" do
      Given {
        FreshBooks::CLI::Auth.save_cache(
          "updated_at" => Time.now.to_i - 60,
          "clients_data" => [{ "id" => 10, "organization" => "Cached" }]
        )
        stub_request(:get, clients_url)
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: {
              "result" => {
                "clients" => [{ "id" => 10, "organization" => "Fresh" }],
                "meta" => { "pages" => 1, "page" => 1 }
              }
            }.to_json
          )
      }
      When(:result) { FreshBooks::CLI::Api.fetch_clients(force: true) }
      Then { result.first["organization"] == "Fresh" }
    end
  end

  # --- build_name_maps with services ---

  describe ".build_name_maps with services" do
    context "with fresh cache including services" do
      Given {
        FreshBooks::CLI::Auth.save_cache(
          "updated_at" => Time.now.to_i - 60,
          "clients" => { "10" => "Client" },
          "projects" => { "20" => "Project" },
          "services" => { "30" => "Development" }
        )
      }
      When(:result) { FreshBooks::CLI::Api.build_name_maps }
      Then { result[:services]["30"] == "Development" }
    end
  end

  # --- business_id / account_id ---

  describe ".business_id" do
    When(:result) { FreshBooks::CLI::Api.business_id }
    Then { result == 12345 }
  end

  describe ".account_id" do
    When(:result) { FreshBooks::CLI::Api.account_id }
    Then { result == "acc99" }
  end

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
          "updated_at" => Time.now.to_i - 700,
          "clients_data" => [{ "id" => 1, "organization" => "Acme" }]
        }
        FreshBooks::CLI::Auth.save_cache(stale_cache)
      }
      When(:result) { FreshBooks::CLI::Api.cached_data("clients_data") }
      Then { result == [{ "id" => 1, "organization" => "Acme" }] }
    end

    describe ".fetch_all_pages returns empty array in dry-run" do
      When(:result) {
        FreshBooks::CLI::Api.fetch_all_pages("https://api.freshbooks.com/fake", "items")
      }
      Then { result == [] }
    end

    describe ".fetch_services returns empty array in dry-run (no HTTP)" do
      When(:result) { FreshBooks::CLI::Api.fetch_services }
      Then { result == [] }
    end

    describe ".fetch_services uses stale cache in dry-run" do
      Given {
        stale_cache = {
          "updated_at" => Time.now.to_i - 700,
          "services_data" => [{ "id" => 5, "name" => "Dev" }]
        }
        FreshBooks::CLI::Auth.save_cache(stale_cache)
      }
      When(:result) { FreshBooks::CLI::Api.fetch_services }
      Then { result == [{ "id" => 5, "name" => "Dev" }] }
    end

    describe ".fetch_time_entry makes real GET in dry-run" do
      Given {
        stub_request(:get, %r{api\.freshbooks\.com/timetracking/business/12345/time_entries/42})
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { "result" => { "time_entry" => { "id" => 42, "duration" => 7200, "is_logged" => true } } }.to_json
          )
      }
      When(:result) { FreshBooks::CLI::Api.fetch_time_entry(42) }
      Then { result["id"] == 42 }
      And  { result["duration"] == 7200 }
    end
  end

  # --- Dry-run write path ---

  describe "dry-run write path" do
    around do |example|
      Thread.current[:fb_dry_run] = true
      example.run
    ensure
      Thread.current[:fb_dry_run] = false
    end

    describe ".create_time_entry returns mock response in dry-run" do
      let(:entry) { { "duration" => 3600, "note" => "test", "client_id" => 10 } }
      When(:result) { FreshBooks::CLI::Api.create_time_entry(entry) }
      Then { result["_dry_run"]["simulated"] == true }
      And  { result["_dry_run"]["payload_sent"] == entry }
      And  { result["result"]["time_entry"]["id"] == 0 }
      And  { result["result"]["time_entry"]["duration"] == 3600 }
    end

    describe ".update_time_entry returns mock response in dry-run" do
      let(:fields) { { "duration" => 5400, "note" => "updated" } }
      When(:result) { FreshBooks::CLI::Api.update_time_entry(99, fields) }
      Then { result["_dry_run"]["simulated"] == true }
      And  { result["_dry_run"]["payload_sent"] == fields }
      And  { result["result"]["time_entry"]["id"] == 99 }
      And  { result["result"]["time_entry"]["duration"] == 5400 }
    end

    describe ".delete_time_entry returns true in dry-run" do
      When(:result) { FreshBooks::CLI::Api.delete_time_entry(99) }
      Then { result == true }
    end
  end
end
