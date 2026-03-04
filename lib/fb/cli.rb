# frozen_string_literal: true

require "thor"
require "json"
require "date"

module FB
  class Cli < Thor
    def self.exit_on_failure?
      true
    end

    # --- version ---

    desc "version", "Print the current version"
    def version
      puts "freshbooks-cli #{VERSION}"
    end

    # --- auth ---

    desc "auth", "Authenticate with FreshBooks via OAuth2"
    def auth
      config = Auth.require_config
      tokens = Auth.authorize(config)
      Auth.discover_business(tokens["access_token"], config)
      puts "\nReady to go! Try: fb entries"
    end

    # --- log ---

    desc "log", "Log a time entry"
    method_option :client, type: :string, desc: "Pre-select client by name"
    method_option :project, type: :string, desc: "Pre-select project by name"
    method_option :service, type: :string, desc: "Pre-select service by name"
    method_option :duration, type: :numeric, desc: "Duration in hours (e.g. 2.5)"
    method_option :note, type: :string, desc: "Work description"
    method_option :date, type: :string, desc: "Date (YYYY-MM-DD, defaults to today)"
    method_option :yes, type: :boolean, default: false, desc: "Skip confirmation"
    def log
      Auth.valid_access_token
      defaults = Auth.load_defaults
      interactive = !(options[:client] && options[:duration] && options[:note])

      client = select_client(defaults, interactive)
      project = select_project(client["id"], defaults, interactive)
      service = select_service(defaults, interactive)
      date = pick_date(interactive)
      duration_hours = pick_duration(interactive)
      note = pick_note(interactive)

      client_name = display_name(client)

      puts "\n--- Time Entry Summary ---"
      puts "  Client:   #{client_name}"
      puts "  Project:  #{project ? project["title"] : "(none)"}"
      puts "  Service:  #{service ? service["name"] : "(none)"}"
      puts "  Date:     #{date}"
      puts "  Duration: #{duration_hours}h"
      puts "  Note:     #{note}"
      puts "--------------------------\n\n"

      unless options[:yes]
        print "Submit? (Y/n): "
        answer = $stdin.gets&.strip&.downcase
        abort("Cancelled.") if answer == "n"
      end

      entry = {
        "is_logged" => true,
        "duration" => (duration_hours * 3600).to_i,
        "note" => note,
        "started_at" => date,
        "client_id" => client["id"]
      }
      entry["project_id"] = project["id"] if project
      entry["service_id"] = service["id"] if service

      Api.create_time_entry(entry)
      puts "Time entry created!"

      new_defaults = { "client_id" => client["id"] }
      new_defaults["project_id"] = project["id"] if project
      new_defaults["service_id"] = service["id"] if service
      Auth.save_defaults(new_defaults)
    end

    # --- entries ---

    desc "entries", "List time entries (defaults to current month)"
    method_option :month, type: :numeric, desc: "Month (1-12)"
    method_option :year, type: :numeric, desc: "Year"
    method_option :from, type: :string, desc: "Start date (YYYY-MM-DD)"
    method_option :to, type: :string, desc: "End date (YYYY-MM-DD)"
    method_option :format, type: :string, default: "table", desc: "Output format: table or json"
    def entries
      Auth.valid_access_token

      today = Date.today

      if options[:from] || options[:to]
        first_day = options[:from] ? Date.parse(options[:from]) : nil
        last_day = options[:to] ? Date.parse(options[:to]) : nil
      else
        month = options[:month] || today.month
        year = options[:year] || today.year
        first_day = Date.new(year, month, 1)
        last_day = Date.new(year, month, -1)
      end

      label = if first_day && last_day
        "#{first_day} to #{last_day}"
      elsif first_day
        "from #{first_day} onwards"
      elsif last_day
        "up to #{last_day}"
      end

      entries = Spinner.spin("Fetching time entries#{label ? " (#{label})" : ""}") do
        Api.fetch_time_entries(
          started_from: first_day&.to_s,
          started_to: last_day&.to_s
        )
      end

      if entries.empty?
        puts "No time entries#{label ? " #{label}" : ""}."
        return
      end

      if options[:format] == "json"
        puts JSON.pretty_generate(entries)
        return
      end

      maps = Spinner.spin("Resolving names") { Api.build_name_maps }
      entries.sort_by! { |e| e["started_at"] || "" }

      rows = entries.map do |e|
        date = e["started_at"] || "?"
        client = maps[:clients][e["client_id"].to_s] || e["client_id"].to_s
        project = maps[:projects][e["project_id"].to_s] || "-"
        note = (e["note"] || "").slice(0, 50)
        hours = (e["duration"].to_i / 3600.0).round(2)
        [date, client, project, note, "#{hours}h"]
      end

      headers = ["Date", "Client", "Project", "Note", "Duration"]
      widths = headers.each_with_index.map do |h, i|
        [h.length, *rows.map { |r| r[i].to_s.length }].max
      end

      fmt = widths.map { |w| "%-#{w}s" }.join("  ")
      puts fmt % headers
      puts widths.map { |w| "-" * w }.join("  ")
      rows.each { |r| puts fmt % r }

      total = entries.sum { |e| e["duration"].to_i } / 3600.0
      puts "\nTotal: #{total.round(2)}h"
    end

    # --- help ---

    desc "help [COMMAND]", "Describe available commands or one specific command"
    method_option :format, type: :string, desc: "Output format: text (default) or json"
    def help(command = nil)
      if options[:format] == "json"
        puts JSON.pretty_generate(help_json)
        return
      end
      super
    end

    private

    def select_client(defaults, interactive)
      clients = Spinner.spin("Fetching clients") { Api.fetch_clients }

      if options[:client]
        match = clients.find { |c| display_name(c).downcase == options[:client].downcase }
        abort("Client not found: #{options[:client]}") unless match
        return match
      end

      abort("No clients found.") if clients.empty?

      puts "\nClients:\n\n"
      clients.each_with_index do |c, i|
        name = display_name(c)
        default_marker = c["id"].to_i == defaults["client_id"].to_i ? " [default]" : ""
        puts "  #{i + 1}. #{name}#{default_marker}"
      end

      default_idx = clients.index { |c| c["id"].to_i == defaults["client_id"].to_i }
      prompt = default_idx ? "\nSelect client (1-#{clients.length}) [#{default_idx + 1}]: " : "\nSelect client (1-#{clients.length}): "
      print prompt
      input = $stdin.gets&.strip

      idx = if input.nil? || input.empty?
        default_idx || 0
      else
        input.to_i - 1
      end

      abort("Invalid selection.") if idx < 0 || idx >= clients.length
      clients[idx]
    end

    def select_project(client_id, defaults, interactive)
      projects = Spinner.spin("Fetching projects") { Api.fetch_projects_for_client(client_id) }

      if options[:project]
        match = projects.find { |p| p["title"].downcase == options[:project].downcase }
        abort("Project not found: #{options[:project]}") unless match
        return match
      end

      return nil if projects.empty?

      puts "\nProjects:\n\n"
      projects.each_with_index do |p, i|
        default_marker = p["id"].to_i == defaults["project_id"].to_i ? " [default]" : ""
        puts "  #{i + 1}. #{p["title"]}#{default_marker}"
      end

      default_idx = projects.index { |p| p["id"].to_i == defaults["project_id"].to_i }
      prompt = default_idx ? "\nSelect project (1-#{projects.length}, Enter to skip) [#{default_idx + 1}]: " : "\nSelect project (1-#{projects.length}, Enter to skip): "
      print prompt
      input = $stdin.gets&.strip

      if input.nil? || input.empty?
        return default_idx ? projects[default_idx] : nil
      end

      idx = input.to_i - 1
      return nil if idx < 0 || idx >= projects.length
      projects[idx]
    end

    def select_service(defaults, interactive)
      if options[:service]
        services = Spinner.spin("Fetching services") { Api.fetch_services }
        match = services.find { |s| s["name"].downcase == options[:service].downcase }
        abort("Service not found: #{options[:service]}") unless match
        return match
      end

      return nil unless interactive

      services = Spinner.spin("Fetching services") { Api.fetch_services }
      return nil if services.empty?

      puts "\nServices:\n\n"
      services.each_with_index do |s, i|
        default_marker = s["id"].to_i == defaults["service_id"].to_i ? " [default]" : ""
        puts "  #{i + 1}. #{s["name"]}#{default_marker}"
      end

      default_idx = services.index { |s| s["id"].to_i == defaults["service_id"].to_i }
      prompt = default_idx ? "\nSelect service (1-#{services.length}, Enter to skip) [#{default_idx + 1}]: " : "\nSelect service (1-#{services.length}, Enter to skip): "
      print prompt
      input = $stdin.gets&.strip

      if input.nil? || input.empty?
        return default_idx ? services[default_idx] : nil
      end

      idx = input.to_i - 1
      return nil if idx < 0 || idx >= services.length
      services[idx]
    end

    def pick_date(interactive)
      return options[:date] if options[:date]

      today = Date.today.to_s
      return today unless interactive

      print "\nDate [#{today}]: "
      input = $stdin.gets&.strip
      (input.nil? || input.empty?) ? today : input
    end

    def pick_duration(interactive)
      return options[:duration] if options[:duration]

      print "\nDuration (hours): "
      input = $stdin.gets&.strip
      abort("Duration is required.") if input.nil? || input.empty?
      input.to_f
    end

    def pick_note(interactive)
      return options[:note] if options[:note]

      print "\nNote: "
      input = $stdin.gets&.strip
      abort("Note is required.") if input.nil? || input.empty?
      input
    end

    def display_name(client)
      name = client["organization"]
      (name.nil? || name.empty?) ? "#{client["fname"]} #{client["lname"]}" : name
    end

    def help_json
      {
        name: "fb",
        description: "FreshBooks time tracking CLI",
        required_scopes: Auth::REQUIRED_SCOPES,
        commands: {
          auth: {
            description: "Authenticate with FreshBooks via OAuth2",
            usage: "fb auth",
            interactive: true
          },
          log: {
            description: "Log a time entry (interactive prompts with defaults from last use)",
            usage: "fb log",
            interactive: true,
            flags: {
              "--client" => "Pre-select client by name (skip prompt)",
              "--project" => "Pre-select project by name (skip prompt)",
              "--service" => "Pre-select service by name (skip prompt)",
              "--duration" => "Duration in hours (e.g. 2.5)",
              "--note" => "Work description",
              "--date" => "Date (YYYY-MM-DD, defaults to today)",
              "--yes" => "Skip confirmation prompt"
            }
          },
          entries: {
            description: "List time entries (defaults to current month)",
            usage: "fb entries",
            flags: {
              "--from" => "Start date (YYYY-MM-DD, open-ended if omitted)",
              "--to" => "End date (YYYY-MM-DD, open-ended if omitted)",
              "--month" => "Month (1-12, defaults to current)",
              "--year" => "Year (defaults to current)",
              "--format" => "Output format: table (default) or json"
            }
          },
          help: {
            description: "Show help information",
            usage: "fb help [COMMAND]",
            flags: {
              "--format" => "Output format: text (default) or json"
            }
          }
        }
      }
    end
  end
end
