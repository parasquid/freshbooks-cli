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

  # --- version ---

  describe "version" do
    When(:output) { capture_stdout { FB::Cli.start(["version"]) } }
    Then { output.strip == "freshbooks-cli #{FB::VERSION}" }
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

  # --- interactive? ---

  describe "interactive?" do
    it "returns false when $stdin.tty? is false" do
      allow($stdin).to receive(:tty?).and_return(false)
      cli = FB::Cli.new
      expect(cli.send(:interactive?)).to eq(false)
    end

    it "returns true when $stdin.tty? is true and --no-interactive is not set" do
      allow($stdin).to receive(:tty?).and_return(true)
      cli = FB::Cli.new([], { no_interactive: false })
      expect(cli.send(:interactive?)).to eq(true)
    end

    it "returns false when --no-interactive is set even if TTY" do
      allow($stdin).to receive(:tty?).and_return(true)
      cli = FB::Cli.new([], { no_interactive: true })
      expect(cli.send(:interactive?)).to eq(false)
    end
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

  # --- clients ---

  describe "clients" do
    let(:clients_url) { %r{api\.freshbooks\.com/accounting/account/acc99/users/clients} }

    context "table output" do
      Given {
        stub_request(:get, clients_url)
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: {
              "result" => {
                "clients" => [
                  { "id" => 10, "organization" => "Acme Corp", "fname" => "J", "lname" => "D", "email" => "j@acme.com" },
                  { "id" => 11, "organization" => "", "fname" => "Jane", "lname" => "Doe", "email" => "jane@example.com" }
                ],
                "meta" => { "pages" => 1, "page" => 1 }
              }
            }.to_json
          )
      }
      When(:output) { capture_stdout { FB::Cli.start(["clients"]) } }
      Then { output.include?("Acme Corp") }
      And  { output.include?("Jane Doe") }
      And  { output.include?("j@acme.com") }
    end

    context "json output" do
      Given {
        stub_request(:get, clients_url)
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: {
              "result" => {
                "clients" => [{ "id" => 10, "organization" => "Acme Corp" }],
                "meta" => { "pages" => 1, "page" => 1 }
              }
            }.to_json
          )
      }
      When(:output) { capture_stdout { FB::Cli.start(["clients", "--format", "json"]) } }
      Then { JSON.parse(output).first["organization"] == "Acme Corp" }
    end

    context "empty" do
      Given {
        stub_request(:get, clients_url)
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { "result" => { "clients" => [], "meta" => { "pages" => 1 } } }.to_json
          )
      }
      When(:output) { capture_stdout { FB::Cli.start(["clients"]) } }
      Then { output.include?("No clients found.") }
    end
  end

  # --- projects ---

  describe "projects" do
    let(:clients_url) { %r{api\.freshbooks\.com/accounting/account/acc99/users/clients} }
    let(:projects_url) { %r{api\.freshbooks\.com/projects/business/12345/projects} }
    let(:services_url) { %r{api\.freshbooks\.com/comments/business/12345/services} }

    before do
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
      stub_request(:get, services_url)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "result" => { "services" => {} } }.to_json
        )
    end

    context "table output" do
      Given {
        stub_request(:get, projects_url)
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: {
              "result" => {
                "projects" => [{ "id" => 20, "title" => "Website Redesign", "client_id" => 10, "active" => true }],
                "meta" => { "pages" => 1, "page" => 1 }
              }
            }.to_json
          )
      }
      When(:output) { capture_stdout { FB::Cli.start(["projects"]) } }
      Then { output.include?("Website Redesign") }
      And  { output.include?("Acme Corp") }
      And  { output.include?("active") }
    end

    context "with --client filter" do
      Given {
        stub_request(:get, projects_url)
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: {
              "result" => {
                "projects" => [
                  { "id" => 20, "title" => "Website Redesign", "client_id" => 10, "active" => true },
                  { "id" => 21, "title" => "Other Project", "client_id" => 99, "active" => true }
                ],
                "meta" => { "pages" => 1, "page" => 1 }
              }
            }.to_json
          )
      }
      When(:output) { capture_stdout { FB::Cli.start(["projects", "--client", "Acme Corp"]) } }
      Then { output.include?("Website Redesign") }
      And  { !output.include?("Other Project") }
    end
  end

  # --- services ---

  describe "services" do
    let(:services_url) { %r{api\.freshbooks\.com/comments/business/12345/services} }

    context "table output" do
      Given {
        stub_request(:get, services_url)
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: {
              "result" => {
                "services" => {
                  "1" => { "id" => 1, "name" => "Development", "billable" => true },
                  "2" => { "id" => 2, "name" => "Design", "billable" => false }
                }
              }
            }.to_json
          )
      }
      When(:output) { capture_stdout { FB::Cli.start(["services"]) } }
      Then { output.include?("Development") }
      And  { output.include?("yes") }
      And  { output.include?("Design") }
      And  { output.include?("no") }
    end

    context "json output" do
      Given {
        stub_request(:get, services_url)
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: {
              "result" => {
                "services" => { "1" => { "id" => 1, "name" => "Development", "billable" => true } }
              }
            }.to_json
          )
      }
      When(:output) { capture_stdout { FB::Cli.start(["services", "--format", "json"]) } }
      Then { JSON.parse(output).first["name"] == "Development" }
    end
  end

  # --- status ---

  describe "status" do
    let(:time_entries_url) { %r{api\.freshbooks\.com/timetracking/business/12345/time_entries} }
    let(:clients_url) { %r{api\.freshbooks\.com/accounting/account/acc99/users/clients} }
    let(:projects_url) { %r{api\.freshbooks\.com/projects/business/12345/projects} }
    let(:services_url) { %r{api\.freshbooks\.com/comments/business/12345/services} }

    let(:stub_all) {
      today = Date.today.to_s
      stub_request(:get, time_entries_url)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "result" => {
              "time_entries" => [
                { "id" => 1, "client_id" => 10, "project_id" => 20, "duration" => 3600, "started_at" => today, "note" => "Work" }
              ],
              "meta" => { "pages" => 1, "page" => 1 }
            }
          }.to_json
        )
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
              "projects" => [{ "id" => 20, "title" => "Website" }],
              "meta" => { "pages" => 1, "page" => 1 }
            }
          }.to_json
        )
      stub_request(:get, services_url)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "result" => { "services" => {} } }.to_json
        )
    }

    context "with entries" do
      Given { stub_all }
      When(:output) { capture_stdout { FB::Cli.start(["status"]) } }
      Then { output.include?("Today") }
      And  { output.include?("This Week") }
      And  { output.include?("This Month") }
      And  { output.include?("Acme Corp / Website") }
      And  { output.include?("1.0h") }
    end

    context "with --format json" do
      Given { stub_all }
      When(:output) { capture_stdout { FB::Cli.start(["status", "--format", "json"]) } }
      Then {
        json = JSON.parse(output)
        json.key?("today") && json.key?("this_week") && json.key?("this_month") &&
          json["today"]["total_hours"] == 1.0 &&
          json["today"]["entries"].first["client"] == "Acme Corp"
      }
    end
  end

  # --- delete ---

  describe "delete" do
    let(:time_entries_url) { %r{api\.freshbooks\.com/timetracking/business/12345/time_entries} }

    context "with --id and --yes" do
      Given {
        stub_request(:delete, %r{api\.freshbooks\.com/timetracking/business/12345/time_entries/999})
          .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: "")
      }
      When(:output) {
        capture_stdout { FB::Cli.start(["delete", "--id", "999", "--yes"]) }
      }
      Then { output.include?("Time entry 999 deleted.") }
    end

    context "with --id and confirmation denied" do
      Given {
        allow($stdin).to receive(:gets).and_return("n\n")
      }
      When(:result) {
        capture_stdout { FB::Cli.start(["delete", "--id", "999"]) }
      }
      Then { result == Failure(SystemExit) }
    end

    context "with --id --yes --format json" do
      Given {
        stub_request(:delete, %r{api\.freshbooks\.com/timetracking/business/12345/time_entries/999})
          .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: "")
      }
      When(:output) {
        capture_stdout { FB::Cli.start(["delete", "--id", "999", "--yes", "--format", "json"]) }
      }
      Then {
        json = JSON.parse(output)
        json["id"] == 999 && json["deleted"] == true
      }
    end

    context "non-interactive without --id aborts" do
      Given {
        allow($stdin).to receive(:tty?).and_return(false)
      }
      When(:result) {
        capture_stdout { FB::Cli.start(["delete"]) }
      }
      Then { result == Failure(SystemExit) }
    end
  end

  # --- edit ---

  describe "edit" do
    let(:entry_url) { %r{api\.freshbooks\.com/timetracking/business/12345/time_entries/999} }
    let(:clients_url) { %r{api\.freshbooks\.com/accounting/account/acc99/users/clients} }
    let(:projects_url) { %r{api\.freshbooks\.com/projects/business/12345/projects} }
    let(:services_url) { %r{api\.freshbooks\.com/comments/business/12345/services} }

    let(:stub_edit_apis) {
      stub_request(:get, entry_url)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "result" => {
              "time_entry" => { "id" => 999, "duration" => 3600, "note" => "Old note",
                                "started_at" => "2024-03-01", "client_id" => 10, "project_id" => 20 }
            }
          }.to_json
        )
      stub_request(:put, entry_url)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "result" => { "time_entry" => { "id" => 999, "duration" => 5400 } } }.to_json
        )
      stub_request(:get, clients_url)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "result" => {
              "clients" => [{ "id" => 10, "organization" => "Acme", "fname" => "J", "lname" => "D" }],
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
              "projects" => [{ "id" => 20, "title" => "Website" }],
              "meta" => { "pages" => 1, "page" => 1 }
            }
          }.to_json
        )
      stub_request(:get, services_url)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "result" => { "services" => {} } }.to_json
        )
    }

    context "scripted with --id, --duration, --yes" do
      Given { stub_edit_apis }
      When(:output) {
        capture_stdout { FB::Cli.start(["edit", "--id", "999", "--duration", "1.5", "--yes"]) }
      }
      Then { output.include?("Time entry 999 updated.") }
      And  { output.include?("Edit Summary") }
    end

    context "with --format json" do
      Given { stub_edit_apis }
      When(:output) {
        capture_stdout { FB::Cli.start(["edit", "--id", "999", "--duration", "1.5", "--yes", "--format", "json"]) }
      }
      Then {
        json = JSON.parse(output)
        json["result"]["time_entry"]["id"] == 999
      }
    end

    context "non-interactive without --id aborts" do
      Given {
        allow($stdin).to receive(:tty?).and_return(false)
      }
      When(:result) {
        capture_stdout { FB::Cli.start(["edit"]) }
      }
      Then { result == Failure(SystemExit) }
    end
  end

  # --- log ---

  describe "log" do
    let(:clients_url) { %r{api\.freshbooks\.com/accounting/account/acc99/users/clients} }
    let(:projects_url) { %r{api\.freshbooks\.com/projects/business/12345/projects} }
    let(:services_url) { %r{api\.freshbooks\.com/comments/business/12345/services} }
    let(:time_entries_url) { %r{api\.freshbooks\.com/timetracking/business/12345/time_entries} }

    let(:stub_log_apis) {
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
              "projects" => [],
              "meta" => { "pages" => 1, "page" => 1 }
            }
          }.to_json
        )
      stub_request(:get, services_url)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "result" => { "services" => {} } }.to_json
        )
      stub_request(:post, time_entries_url)
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            "result" => {
              "time_entry" => { "id" => 555, "duration" => 9000, "note" => "test work" }
            }
          }.to_json
        )
    }

    context "non-interactive with all flags" do
      Given { stub_log_apis }
      When(:output) {
        capture_stdout {
          FB::Cli.start(["log", "--client", "Acme Corp", "--duration", "2.5", "--note", "test work", "--yes"])
        }
      }
      Then { output.include?("Time entry created!") }
    end

    context "non-interactive with --format json" do
      Given { stub_log_apis }
      When(:output) {
        capture_stdout {
          FB::Cli.start(["log", "--client", "Acme Corp", "--duration", "2.5", "--note", "test work", "--yes", "--format", "json"])
        }
      }
      Then {
        json = JSON.parse(output)
        json["result"]["time_entry"]["id"] == 555
      }
    end

    context "non-interactive missing --duration aborts" do
      Given {
        allow($stdin).to receive(:tty?).and_return(false)
        stub_log_apis
      }
      When(:result) {
        capture_stdout {
          FB::Cli.start(["log", "--client", "Acme Corp", "--note", "test work", "--yes"])
        }
      }
      Then { result == Failure(SystemExit) }
    end

    context "non-interactive missing --note aborts" do
      Given {
        allow($stdin).to receive(:tty?).and_return(false)
        stub_log_apis
      }
      When(:result) {
        capture_stdout {
          FB::Cli.start(["log", "--client", "Acme Corp", "--duration", "2.5", "--yes"])
        }
      }
      Then { result == Failure(SystemExit) }
    end

    context "non-interactive single client auto-selects" do
      Given {
        allow($stdin).to receive(:tty?).and_return(false)
        stub_log_apis
      }
      When(:output) {
        capture_stdout {
          FB::Cli.start(["log", "--duration", "2.5", "--note", "test work", "--yes"])
        }
      }
      Then { output.include?("Time entry created!") }
    end

    context "non-interactive multiple clients aborts without --client" do
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
      }
      When(:result) {
        capture_stdout {
          FB::Cli.start(["log", "--duration", "2.5", "--note", "test", "--yes"])
        }
      }
      Then { result == Failure(SystemExit) }
    end
  end

  # --- cache ---

  describe "cache" do
    context "status with no cache" do
      When(:output) { capture_stdout { FB::Cli.start(["cache", "status"]) } }
      Then { output.include?("No cache data.") }
    end

    context "status with existing cache" do
      Given {
        FB::Auth.save_cache(
          "updated_at" => Time.now.to_i - 30,
          "clients_data" => [{ "id" => 1 }],
          "projects_data" => [{ "id" => 2 }, { "id" => 3 }],
          "services_data" => []
        )
      }
      When(:output) { capture_stdout { FB::Cli.start(["cache", "status"]) } }
      Then { output.include?("fresh") }
      And  { output.include?("Clients: 1") }
      And  { output.include?("Projects: 2") }
    end

    context "status with --format json" do
      Given {
        FB::Auth.save_cache(
          "updated_at" => Time.now.to_i - 30,
          "clients_data" => [{ "id" => 1 }],
          "projects_data" => [{ "id" => 2 }, { "id" => 3 }],
          "services_data" => []
        )
      }
      When(:output) { capture_stdout { FB::Cli.start(["cache", "status", "--format", "json"]) } }
      Then {
        json = JSON.parse(output)
        json["fresh"] == true && json["clients"] == 1 && json["projects"] == 2
      }
    end

    context "status with --format json and no cache" do
      When(:output) { capture_stdout { FB::Cli.start(["cache", "status", "--format", "json"]) } }
      Then {
        json = JSON.parse(output)
        json["fresh"] == false && json["clients"] == 0
      }
    end

    context "clear with existing cache" do
      Given {
        FB::Auth.save_cache("updated_at" => Time.now.to_i)
      }
      When(:output) { capture_stdout { FB::Cli.start(["cache", "clear"]) } }
      Then { output.include?("Cache cleared.") }
      And  { !File.exist?(FB::Auth.cache_path) }
    end

    context "clear with no cache" do
      When(:output) { capture_stdout { FB::Cli.start(["cache", "clear"]) } }
      Then { output.include?("No cache file found.") }
    end
  end

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

    context "url with config" do
      Given {
        FB::Auth.save_config("client_id" => "cid", "client_secret" => "csec")
      }
      When(:output) {
        capture_stdout { FB::Cli.start(["auth", "url"]) }
      }
      Then { output.include?("auth.freshbooks.com/oauth/authorize") }
      And  { output.include?("client_id=cid") }
    end

    context "url with --format json" do
      Given {
        FB::Auth.save_config("client_id" => "cid", "client_secret" => "csec")
      }
      When(:output) {
        capture_stdout { FB::Cli.start(["auth", "url", "--format", "json"]) }
      }
      Then {
        json = JSON.parse(output)
        json["url"].include?("auth.freshbooks.com")
      }
    end

    context "url without config aborts" do
      When(:result) {
        capture_stdout { FB::Cli.start(["auth", "url"]) }
      }
      Then { result == Failure(SystemExit) }
    end

    context "status" do
      When(:output) {
        capture_stdout { FB::Cli.start(["auth", "status"]) }
      }
      Then { output.include?("Config:") }
      And  { output.include?("Tokens:") }
    end

    context "status with --format json" do
      When(:output) {
        capture_stdout { FB::Cli.start(["auth", "status", "--format", "json"]) }
      }
      Then {
        json = JSON.parse(output)
        json.key?("config_exists") && json.key?("tokens_exist")
      }
    end

    context "non-interactive without subcommand aborts" do
      Given {
        allow($stdin).to receive(:tty?).and_return(false)
      }
      When(:result) {
        capture_stdout { FB::Cli.start(["auth"]) }
      }
      Then { result == Failure(SystemExit) }
    end
  end

  # --- entries with ID column ---

  describe "entries table includes ID column" do
    let(:time_entries_url) { %r{api\.freshbooks\.com/timetracking/business/12345/time_entries} }
    let(:clients_url) { %r{api\.freshbooks\.com/accounting/account/acc99/users/clients} }
    let(:projects_url) { %r{api\.freshbooks\.com/projects/business/12345/projects} }
    let(:services_url) { %r{api\.freshbooks\.com/comments/business/12345/services} }

    context "table output shows ID" do
      Given {
        stub_request(:get, time_entries_url)
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: {
              "result" => {
                "time_entries" => [
                  { "id" => 42, "client_id" => 10, "project_id" => 20, "duration" => 3600,
                    "started_at" => "2024-03-01", "note" => "Work" }
                ],
                "meta" => { "pages" => 1, "page" => 1 }
              }
            }.to_json
          )
        stub_request(:get, clients_url)
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: {
              "result" => {
                "clients" => [{ "id" => 10, "organization" => "Acme", "fname" => "J", "lname" => "D" }],
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
                "projects" => [{ "id" => 20, "title" => "Website" }],
                "meta" => { "pages" => 1, "page" => 1 }
              }
            }.to_json
          )
        stub_request(:get, services_url)
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { "result" => { "services" => {} } }.to_json
          )
      }
      When(:output) {
        capture_stdout { FB::Cli.start(["entries", "--from", "2024-03-01", "--to", "2024-03-31"]) }
      }
      Then { output.include?("ID") }
      And  { output.include?("42") }
    end
  end

  # --- help --format json includes new commands ---

  describe "help --format json includes new commands" do
    When(:output) {
      capture_stdout { FB::Cli.start(["help", "--format", "json"]) }
    }
    Then {
      json = JSON.parse(output)
      cmds = json["commands"]
      cmds.key?("clients") && cmds.key?("projects") && cmds.key?("services") &&
        cmds.key?("status") && cmds.key?("delete") && cmds.key?("edit") && cmds.key?("cache") &&
        cmds.key?("auth") && cmds.key?("business") &&
        json.key?("global_flags")
    }
  end

  # --- dry-run flag in help --format json ---

  describe "help --format json includes --dry-run in global_flags" do
    When(:output) {
      capture_stdout { FB::Cli.start(["help", "--format", "json"]) }
    }
    Then { JSON.parse(output)["global_flags"].key?("--dry-run") }
  end

  # --- dry-run banner ---

  describe "--dry-run banner" do
    When(:stderr_output) {
      capture_stderr { capture_stdout { FB::Cli.start(["version", "--dry-run"]) } }
    }
    Then { stderr_output.include?("[DRY RUN]") }
  end

  # --- dry-run integration ---

  describe "dry-run integration" do
    let(:stale_cache) {
      {
        "updated_at" => Time.now.to_i - 700,
        "clients_data" => [{ "id" => 10, "organization" => "Acme Corp", "fname" => "", "lname" => "" }],
        "projects_data" => [],
        "services_data" => [],
        "clients" => { "10" => "Acme Corp" },
        "projects" => {},
        "services" => {}
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
            FB::Cli.start(["edit", "--id", "999", "--duration", "2.0", "--yes", "--dry-run"])
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
      context "table output uses stale cache" do
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

def capture_stderr
  original = $stderr
  $stderr = StringIO.new
  yield
  $stderr.string
ensure
  $stderr = original
end
