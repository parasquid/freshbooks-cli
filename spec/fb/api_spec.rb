# frozen_string_literal: true

require "json"

RSpec.describe FB::Api do
  let(:access_token) { "test_token_123" }
  let(:config) {
    { "client_id" => "cid", "client_secret" => "csec",
      "business_id" => 12345, "account_id" => "acc99" }
  }

  before do
    allow(FB::Auth).to receive(:valid_access_token).and_return(access_token)
    allow(FB::Auth).to receive(:require_config).and_return(config)
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
      FB::Api.fetch_time_entries(started_from: "2024-03-01", started_to: "2024-03-31")
    }
    Then { result.length == 1 }
    And  { result.first["id"] == 1 }
  end

  # --- Pagination ---

  describe ".fetch_all_pages" do
    context "with 2-page response" do
      Given {
        url = "#{FB::Api::BASE}/timetracking/business/12345/time_entries"
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
        FB::Api.fetch_all_pages(
          "#{FB::Api::BASE}/timetracking/business/12345/time_entries",
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
      }
      When(:result) { FB::Api.build_name_maps }
      Then { result[:clients]["10"] == "Acme Corp" }
      And  { result[:projects]["20"] == "Website Redesign" }
    end

    context "with fresh cache (< 10 min old)" do
      Given {
        FB::Auth.save_cache(
          "updated_at" => Time.now.to_i - 60,
          "clients" => { "10" => "Cached Client" },
          "projects" => { "20" => "Cached Project" }
        )
      }
      When(:result) { FB::Api.build_name_maps }
      Then { result[:clients]["10"] == "Cached Client" }
      And  { result[:projects]["20"] == "Cached Project" }
      And  {
        assert_not_requested(:get, %r{api\.freshbooks\.com})
        true
      }
    end
  end

  # --- business_id / account_id ---

  describe ".business_id" do
    When(:result) { FB::Api.business_id }
    Then { result == 12345 }
  end

  describe ".account_id" do
    When(:result) { FB::Api.account_id }
    Then { result == "acc99" }
  end
end
