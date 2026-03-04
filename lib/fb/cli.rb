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
        [e["id"].to_s, date, client, project, note, "#{hours}h"]
      end

      print_table(["ID", "Date", "Client", "Project", "Note", "Duration"], rows)

      total = entries.sum { |e| e["duration"].to_i } / 3600.0
      puts "\nTotal: #{total.round(2)}h"
    end

    # --- clients ---

    desc "clients", "List all clients"
    method_option :format, type: :string, default: "table", desc: "Output format: table or json"
    def clients
      Auth.valid_access_token
      clients = Spinner.spin("Fetching clients") { Api.fetch_clients }

      if clients.empty?
        puts "No clients found."
        return
      end

      if options[:format] == "json"
        puts JSON.pretty_generate(clients)
        return
      end

      rows = clients.map do |c|
        name = c["organization"]
        name = "#{c["fname"]} #{c["lname"]}" if name.nil? || name.empty?
        email = c["email"] || "-"
        org = c["organization"] || "-"
        [name, email, org]
      end

      print_table(["Name", "Email", "Organization"], rows)
    end

    # --- projects ---

    desc "projects", "List all projects"
    method_option :format, type: :string, default: "table", desc: "Output format: table or json"
    method_option :client, type: :string, desc: "Filter by client name"
    def projects
      Auth.valid_access_token
      maps = Spinner.spin("Resolving names") { Api.build_name_maps }

      projects = if options[:client]
        client_id = maps[:clients].find { |_id, name| name.downcase == options[:client].downcase }&.first
        abort("Client not found: #{options[:client]}") unless client_id
        Spinner.spin("Fetching projects") { Api.fetch_projects_for_client(client_id) }
      else
        Spinner.spin("Fetching projects") { Api.fetch_projects }
      end

      if projects.empty?
        puts "No projects found."
        return
      end

      if options[:format] == "json"
        puts JSON.pretty_generate(projects)
        return
      end

      rows = projects.map do |p|
        client_name = maps[:clients][p["client_id"].to_s] || "-"
        [p["title"], client_name, p["active"] ? "active" : "inactive"]
      end

      print_table(["Title", "Client", "Status"], rows)
    end

    # --- services ---

    desc "services", "List all services"
    method_option :format, type: :string, default: "table", desc: "Output format: table or json"
    def services
      Auth.valid_access_token
      services = Spinner.spin("Fetching services") { Api.fetch_services }

      if services.empty?
        puts "No services found."
        return
      end

      if options[:format] == "json"
        puts JSON.pretty_generate(services)
        return
      end

      rows = services.map do |s|
        billable = s["billable"] ? "yes" : "no"
        [s["name"], billable]
      end

      print_table(["Name", "Billable"], rows)
    end

    # --- status ---

    desc "status", "Show hours summary for today, this week, and this month"
    def status
      Auth.valid_access_token
      today = Date.today
      week_start = today - ((today.wday - 1) % 7)
      month_start = Date.new(today.year, today.month, 1)

      entries = Spinner.spin("Fetching time entries") do
        Api.fetch_time_entries(started_from: month_start.to_s, started_to: today.to_s)
      end
      maps = Spinner.spin("Resolving names") { Api.build_name_maps }

      today_entries = entries.select { |e| e["started_at"] == today.to_s }
      week_entries = entries.select { |e| d = e["started_at"]; d && d >= week_start.to_s && d <= today.to_s }
      month_entries = entries

      print_status_section("Today (#{today})", today_entries, maps)
      print_status_section("This Week (#{week_start} to #{today})", week_entries, maps)
      print_status_section("This Month (#{month_start} to #{today})", month_entries, maps)
    end

    # --- delete ---

    desc "delete", "Delete a time entry"
    method_option :id, type: :numeric, desc: "Time entry ID (skip interactive picker)"
    method_option :yes, type: :boolean, default: false, desc: "Skip confirmation"
    def delete
      Auth.valid_access_token

      if options[:id]
        entry_id = options[:id]
      else
        entry_id = pick_entry_interactive("delete")
      end

      unless options[:yes]
        print "Delete entry #{entry_id}? (y/N): "
        answer = $stdin.gets&.strip&.downcase
        abort("Cancelled.") unless answer == "y"
      end

      Spinner.spin("Deleting time entry") { Api.delete_time_entry(entry_id) }
      puts "Time entry #{entry_id} deleted."
    end

    # --- edit ---

    desc "edit", "Edit a time entry"
    method_option :id, type: :numeric, desc: "Time entry ID (skip interactive picker)"
    method_option :duration, type: :numeric, desc: "New duration in hours"
    method_option :note, type: :string, desc: "New note"
    method_option :date, type: :string, desc: "New date (YYYY-MM-DD)"
    method_option :client, type: :string, desc: "New client name"
    method_option :project, type: :string, desc: "New project name"
    method_option :service, type: :string, desc: "New service name"
    method_option :yes, type: :boolean, default: false, desc: "Skip confirmation"
    def edit
      Auth.valid_access_token

      entry_id = options[:id] || pick_entry_interactive("edit")
      entry = Spinner.spin("Fetching time entry") { Api.fetch_time_entry(entry_id) }
      abort("Time entry not found.") unless entry

      maps = Spinner.spin("Resolving names") { Api.build_name_maps }
      scripted = options[:duration] || options[:note] || options[:date] || options[:client] || options[:project] || options[:service]

      fields = build_edit_fields(entry, maps, scripted)

      current_client = maps[:clients][entry["client_id"].to_s] || entry["client_id"].to_s
      current_project = maps[:projects][entry["project_id"].to_s] || "-"
      current_hours = (entry["duration"].to_i / 3600.0).round(2)
      new_hours = fields["duration"] ? (fields["duration"].to_i / 3600.0).round(2) : current_hours

      puts "\n--- Edit Summary ---"
      puts "  Date:     #{fields["started_at"] || entry["started_at"]}"
      puts "  Client:   #{fields["client_id"] ? maps[:clients][fields["client_id"].to_s] : current_client}"
      puts "  Project:  #{fields["project_id"] ? maps[:projects][fields["project_id"].to_s] : current_project}"
      puts "  Duration: #{new_hours}h"
      puts "  Note:     #{fields["note"] || entry["note"]}"
      puts "--------------------\n\n"

      unless options[:yes]
        print "Save changes? (Y/n): "
        answer = $stdin.gets&.strip&.downcase
        abort("Cancelled.") if answer == "n"
      end

      Spinner.spin("Updating time entry") { Api.update_time_entry(entry_id, fields) }
      puts "Time entry #{entry_id} updated."
    end

    # --- cache ---

    desc "cache SUBCOMMAND", "Manage cached data (refresh, clear, status)"
    def cache(subcommand = "status")
      case subcommand
      when "refresh"
        Auth.valid_access_token
        Spinner.spin("Refreshing cache") do
          Api.fetch_clients(force: true)
          Api.fetch_projects(force: true)
          Api.fetch_services(force: true)
          Api.build_name_maps
        end
        puts "Cache refreshed."
      when "clear"
        if File.exist?(Auth.cache_path)
          File.delete(Auth.cache_path)
          puts "Cache cleared."
        else
          puts "No cache file found."
        end
      when "status"
        cache = Auth.load_cache
        if cache["updated_at"]
          age = Time.now.to_i - cache["updated_at"]
          updated = Time.at(cache["updated_at"]).strftime("%Y-%m-%d %H:%M:%S")
          fresh = age < 600
          puts "Cache updated: #{updated}"
          puts "Age: #{age}s (#{fresh ? "fresh" : "stale"})"
          puts "Clients: #{(cache["clients_data"] || []).length}"
          puts "Projects: #{(cache["projects_data"] || []).length}"
          puts "Services: #{(cache["services_data"] || []).length}"
        else
          puts "No cache data."
        end
      else
        abort("Unknown cache subcommand: #{subcommand}. Use: refresh, clear, status")
      end
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

    def print_table(headers, rows)
      widths = headers.each_with_index.map do |h, i|
        [h.length, *rows.map { |r| r[i].to_s.length }].max
      end

      fmt = widths.map { |w| "%-#{w}s" }.join("  ")
      puts fmt % headers
      puts widths.map { |w| "-" * w }.join("  ")
      rows.each { |r| puts fmt % r }
    end

    def print_status_section(title, entries, maps)
      puts "\n#{title}"
      if entries.empty?
        puts "  No entries."
        return
      end

      grouped = {}
      entries.each do |e|
        client = maps[:clients][e["client_id"].to_s] || e["client_id"].to_s
        project = maps[:projects][e["project_id"].to_s] || "-"
        key = "#{client} / #{project}"
        grouped[key] ||= 0.0
        grouped[key] += e["duration"].to_i / 3600.0
      end

      grouped.each do |key, hours|
        puts "  #{key}: #{hours.round(2)}h"
      end

      total = entries.sum { |e| e["duration"].to_i } / 3600.0
      puts "  Total: #{total.round(2)}h"
    end

    def pick_entry_interactive(action)
      today = Date.today.to_s
      entries = Spinner.spin("Fetching today's entries") do
        Api.fetch_time_entries(started_from: today, started_to: today)
      end
      abort("No entries found for today.") if entries.empty?

      maps = Spinner.spin("Resolving names") { Api.build_name_maps }

      puts "\nToday's entries:\n\n"
      entries.each_with_index do |e, i|
        client = maps[:clients][e["client_id"].to_s] || e["client_id"].to_s
        hours = (e["duration"].to_i / 3600.0).round(2)
        note = (e["note"] || "").slice(0, 40)
        puts "  #{i + 1}. [#{e["id"]}] #{client} — #{hours}h — #{note}"
      end

      print "\nSelect entry to #{action} (1-#{entries.length}): "
      input = $stdin.gets&.strip
      abort("Cancelled.") if input.nil? || input.empty?

      idx = input.to_i - 1
      abort("Invalid selection.") if idx < 0 || idx >= entries.length
      entries[idx]["id"]
    end

    def build_edit_fields(entry, maps, scripted)
      fields = {}

      if scripted
        fields["duration"] = (options[:duration] * 3600).to_i if options[:duration]
        fields["note"] = options[:note] if options[:note]
        fields["started_at"] = options[:date] if options[:date]

        if options[:client]
          client_id = maps[:clients].find { |_id, name| name.downcase == options[:client].downcase }&.first
          abort("Client not found: #{options[:client]}") unless client_id
          fields["client_id"] = client_id.to_i
        end

        if options[:project]
          project_id = maps[:projects].find { |_id, name| name.downcase == options[:project].downcase }&.first
          abort("Project not found: #{options[:project]}") unless project_id
          fields["project_id"] = project_id.to_i
        end

        if options[:service]
          service_id = maps[:services].find { |_id, name| name.downcase == options[:service].downcase }&.first
          abort("Service not found: #{options[:service]}") unless service_id
          fields["service_id"] = service_id.to_i
        end
      else
        current_hours = (entry["duration"].to_i / 3600.0).round(2)
        print "\nDuration (hours) [#{current_hours}]: "
        input = $stdin.gets&.strip
        fields["duration"] = (input.to_f * 3600).to_i unless input.nil? || input.empty?

        current_note = entry["note"] || ""
        print "Note [#{current_note}]: "
        input = $stdin.gets&.strip
        fields["note"] = input unless input.nil? || input.empty?

        current_date = entry["started_at"] || ""
        print "Date [#{current_date}]: "
        input = $stdin.gets&.strip
        fields["started_at"] = input unless input.nil? || input.empty?
      end

      fields
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
          clients: {
            description: "List all clients",
            usage: "fb clients",
            flags: {
              "--format" => "Output format: table (default) or json"
            }
          },
          projects: {
            description: "List all projects",
            usage: "fb projects",
            flags: {
              "--client" => "Filter by client name",
              "--format" => "Output format: table (default) or json"
            }
          },
          services: {
            description: "List all services",
            usage: "fb services",
            flags: {
              "--format" => "Output format: table (default) or json"
            }
          },
          status: {
            description: "Show hours summary for today, this week, and this month",
            usage: "fb status"
          },
          delete: {
            description: "Delete a time entry",
            usage: "fb delete",
            interactive: true,
            flags: {
              "--id" => "Time entry ID (skip interactive picker)",
              "--yes" => "Skip confirmation prompt"
            }
          },
          edit: {
            description: "Edit a time entry",
            usage: "fb edit",
            interactive: true,
            flags: {
              "--id" => "Time entry ID (skip interactive picker)",
              "--duration" => "New duration in hours",
              "--note" => "New note",
              "--date" => "New date (YYYY-MM-DD)",
              "--client" => "New client name",
              "--project" => "New project name",
              "--service" => "New service name",
              "--yes" => "Skip confirmation prompt"
            }
          },
          cache: {
            description: "Manage cached data",
            usage: "fb cache [refresh|clear|status]",
            subcommands: {
              "refresh" => "Force-refresh all cached data",
              "clear" => "Delete cache file",
              "status" => "Show cache age and staleness"
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
