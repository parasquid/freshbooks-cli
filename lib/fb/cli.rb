# frozen_string_literal: true

require "thor"
require "json"
require "date"
require "io/console"
require "stringio"

module FB
  class Cli < Thor
    def self.exit_on_failure?
      true
    end

    class_option :no_interactive, type: :boolean, default: false, desc: "Disable interactive prompts (auto-detected when not a TTY)"
    class_option :interactive, type: :boolean, default: false, desc: "Force interactive mode even when not a TTY"
    class_option :format, type: :string, desc: "Output format: table (default) or json"
    class_option :dry_run, type: :boolean, default: false, desc: "Simulate command without making network calls"

    no_commands do
      def invoke_command(command, *args)
        Spinner.interactive = interactive?
        return super unless options[:dry_run]

        Thread.current[:fb_dry_run] = true
        $stderr.puts "[DRY RUN] No changes will be made."

        if options[:format] == "json"
          original_stdout = $stdout
          buffer = StringIO.new
          $stdout = buffer
          begin
            super
          ensure
            $stdout = original_stdout
          end
          begin
            data = JSON.parse(buffer.string)
            meta = { "_dry_run" => { "simulated" => true } }
            wrapped = data.is_a?(Array) ? meta.merge("data" => data) : data.merge(meta)
            puts JSON.pretty_generate(wrapped)
          rescue JSON::ParserError
            print buffer.string
          end
        else
          super
        end
      ensure
        Thread.current[:fb_dry_run] = false
      end
    end

    # --- version ---

    desc "version", "Print the current version"
    def version
      puts "freshbooks-cli #{VERSION}"
    end

    # --- auth ---

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

      when "url"
        config = Auth.load_config
        abort("No config found. Run: fb auth setup (set FRESHBOOKS_CLIENT_ID and FRESHBOOKS_CLIENT_SECRET first)") unless config
        url = Auth.authorize_url(config)
        if options[:format] == "json"
          puts JSON.pretty_generate({ "url" => url })
        else
          puts url
        end

      when "callback"
        config = Auth.load_config
        abort("No config found. Run: fb auth setup (set FRESHBOOKS_CLIENT_ID and FRESHBOOKS_CLIENT_SECRET first)") unless config
        redirect_url = args.first
        abort("Usage: fb auth callback REDIRECT_URL") unless redirect_url
        code = Auth.extract_code_from_url(redirect_url)
        abort("Could not find 'code' parameter in the URL.") unless code
        tokens = Auth.exchange_code(config, code)

        # Auto-discover businesses
        businesses = Auth.fetch_businesses(tokens["access_token"])
        if businesses.length == 1
          Auth.select_business(config, businesses.first.dig("business", "id"), businesses)
          biz = businesses.first["business"]
          if options[:format] == "json"
            puts JSON.pretty_generate({ "status" => "authenticated", "business" => biz })
          else
            puts "Business auto-selected: #{biz["name"]} (#{biz["id"]})"
          end
        else
          if options[:format] == "json"
            biz_list = businesses.map { |m| m["business"] }
            puts JSON.pretty_generate({ "status" => "authenticated", "businesses" => biz_list, "business_selected" => false })
          else
            puts "Authenticated! Multiple businesses found — select one with: fb business --select ID"
            businesses.each do |m|
              biz = m["business"]
              puts "  #{biz["name"]} (ID: #{biz["id"]})"
            end
          end
        end

      when "status"
        status_data = Auth.auth_status
        if options[:format] == "json"
          puts JSON.pretty_generate(status_data)
        else
          puts "Config: #{status_data["config_exists"] ? "found" : "missing"} (#{status_data["config_path"]})"
          puts "Tokens: #{status_data["tokens_exist"] ? "found" : "missing"}"
          if status_data["tokens_exist"]
            puts "Expired: #{status_data["tokens_expired"] ? "yes" : "no"}"
          end
          puts "Business ID: #{status_data["business_id"] || "not set"}"
          puts "Account ID: #{status_data["account_id"] || "not set"}"
        end

      else
        unless interactive?
          abort("Use auth subcommands for non-interactive auth: fb auth setup, fb auth url, fb auth callback, fb auth status")
        end
        config = Auth.require_config
        tokens = Auth.authorize(config)
        Auth.discover_business(tokens["access_token"], config)
        puts "\nReady to go! Try: fb entries"
      end
    end

    # --- business ---

    desc "business", "List or select a business"
    method_option :select, type: :string, desc: "Set active business by ID (omit value for interactive picker)"
    def business
      Auth.valid_access_token
      config = Auth.load_config
      tokens = Auth.load_tokens
      businesses = Auth.fetch_businesses(tokens["access_token"])

      if businesses.empty?
        abort("No business memberships found on your FreshBooks account.")
      end

      if options[:select]
        Auth.select_business(config, options[:select], businesses)
        selected = businesses.find { |m| m.dig("business", "id").to_s == options[:select].to_s }
        biz = selected["business"]
        if options[:format] == "json"
          puts JSON.pretty_generate(biz)
        else
          puts "Active business: #{biz["name"]} (#{biz["id"]})"
        end
        return
      end

      if options.key?("select") && options[:select].nil?
        # --select with no value: interactive picker
        unless interactive?
          abort("Non-interactive: use --select ID. Available businesses:\n" +
            businesses.map { |m| "  #{m.dig("business", "name")} (ID: #{m.dig("business", "id")})" }.join("\n"))
        end

        puts "\nBusinesses:\n\n"
        businesses.each_with_index do |m, i|
          biz = m["business"]
          active = biz["id"].to_s == config["business_id"].to_s ? " [active]" : ""
          puts "  #{i + 1}. #{biz["name"]} (#{biz["id"]})#{active}"
        end

        print "\nSelect business (1-#{businesses.length}): "
        input = $stdin.gets&.strip
        abort("Cancelled.") if input.nil? || input.empty?

        idx = input.to_i - 1
        abort("Invalid selection.") if idx < 0 || idx >= businesses.length

        selected_biz = businesses[idx]
        Auth.select_business(config, selected_biz.dig("business", "id"), businesses)
        puts "Active business: #{selected_biz.dig("business", "name")} (#{selected_biz.dig("business", "id")})"
        return
      end

      # Default: list businesses
      if options[:format] == "json"
        biz_list = businesses.map do |m|
          biz = m["business"]
          biz.merge("active" => biz["id"].to_s == config["business_id"].to_s)
        end
        puts JSON.pretty_generate(biz_list)
      else
        businesses.each do |m|
          biz = m["business"]
          active = biz["id"].to_s == config["business_id"].to_s ? " [active]" : ""
          puts "#{biz["name"]} (ID: #{biz["id"]})#{active}"
        end
      end
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

      client = select_client(defaults)
      project = select_project(client["id"], defaults)
      service = select_service(defaults, project)
      date = pick_date
      duration_hours = pick_duration
      note = pick_note

      client_name = display_name(client)

      unless options[:format] == "json"
        puts "\n--- Time Entry Summary ---"
        puts "  Client:   #{client_name}"
        puts "  Project:  #{project ? project["title"] : "(none)"}"
        puts "  Service:  #{service ? service["name"] : "(none)"}"
        puts "  Date:     #{date}"
        puts "  Duration: #{duration_hours}h"
        puts "  Note:     #{note}"
        puts "--------------------------\n\n"
      end

      unless options[:yes]
        print "Submit? (Y/n): "
        answer = $stdin.gets&.strip&.downcase
        abort("Cancelled.") if answer == "n"
      end

      entry = {
        "is_logged" => true,
        "duration" => (duration_hours * 3600).to_i,
        "note" => note,
        "started_at" => normalize_datetime(date),
        "client_id" => client["id"]
      }
      entry["project_id"] = project["id"] if project
      entry["service_id"] = service["id"] if service

      result = Api.create_time_entry(entry)

      if options[:format] == "json"
        puts JSON.pretty_generate(result)
      else
        puts "Time entry created!"
      end

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
        if options[:format] == "json"
          puts "[]"
        else
          puts "No time entries#{label ? " #{label}" : ""}."
        end
        return
      end

      if options[:format] == "json"
        puts JSON.pretty_generate(entries)
        return
      end

      maps = Spinner.spin("Resolving names") { Api.build_name_maps }
      entries.sort_by! { |e| e["started_at"] || "" }

      rows = entries.map do |e|
        date = (e["local_started_at"] || e["started_at"] || "?").slice(0, 10)
        client = maps[:clients][e["client_id"].to_s] || e["client_id"].to_s
        project = maps[:projects][e["project_id"].to_s] || "-"
        service = maps[:services][e["service_id"].to_s] || "-"
        note = e["note"] || ""
        hours = (e["duration"].to_i / 3600.0).round(2)
        [e["id"].to_s, date, client, project, service, note, "#{hours}h"]
      end

      print_table(["ID", "Date", "Client", "Project", "Service", "Note", "Duration"], rows, wrap_col: 5)

      total = entries.sum { |e| e["duration"].to_i } / 3600.0

      # Per-client breakdown
      by_client = entries.group_by { |e| maps[:clients][e["client_id"].to_s] || e["client_id"].to_s }
      if by_client.length > 1
        puts "\nBy client:"
        by_client.sort_by { |_, es| -es.sum { |e| e["duration"].to_i } }.each do |name, es|
          puts "  #{name}: #{(es.sum { |e| e["duration"].to_i } / 3600.0).round(2)}h"
        end
      end

      # Per-service breakdown
      by_service = entries.group_by { |e| maps[:services][e["service_id"].to_s] || "-" }
      if by_service.length > 1
        puts "\nBy service:"
        by_service.sort_by { |_, es| -es.sum { |e| e["duration"].to_i } }.each do |name, es|
          puts "  #{name}: #{(es.sum { |e| e["duration"].to_i } / 3600.0).round(2)}h"
        end
      end

      puts "\nTotal: #{total.round(2)}h"
    end

    # --- clients ---

    desc "clients", "List all clients"
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

      if options[:format] == "json"
        puts JSON.pretty_generate({
          "today" => build_status_data(today.to_s, today.to_s, today_entries, maps),
          "this_week" => build_status_data(week_start.to_s, today.to_s, week_entries, maps),
          "this_month" => build_status_data(month_start.to_s, today.to_s, month_entries, maps)
        })
        return
      end

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
        abort("Missing required flag: --id") unless interactive?
        entry_id = pick_entry_interactive("delete")
      end

      unless options[:yes]
        print "Delete entry #{entry_id}? (y/N): "
        answer = $stdin.gets&.strip&.downcase
        abort("Cancelled.") unless answer == "y"
      end

      Spinner.spin("Deleting time entry") { Api.delete_time_entry(entry_id) }

      if options[:format] == "json"
        puts JSON.pretty_generate({ "id" => entry_id, "deleted" => true })
      else
        puts "Time entry #{entry_id} deleted."
      end
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

      if options[:id]
        entry_id = options[:id]
      else
        abort("Missing required flag: --id") unless interactive?
        entry_id = pick_entry_interactive("edit")
      end

      entry = Spinner.spin("Fetching time entry") { Api.fetch_time_entry(entry_id) }
      abort("Time entry not found.") unless entry

      maps = Spinner.spin("Resolving names") { Api.build_name_maps }
      has_edit_flags = options[:duration] || options[:note] || options[:date] || options[:client] || options[:project] || options[:service]
      scripted = has_edit_flags || !interactive?

      fields = build_edit_fields(entry, maps, scripted)

      current_client = maps[:clients][entry["client_id"].to_s] || entry["client_id"].to_s
      current_project = maps[:projects][entry["project_id"].to_s] || "-"
      current_hours = (entry["duration"].to_i / 3600.0).round(2)
      new_hours = fields["duration"] ? (fields["duration"].to_i / 3600.0).round(2) : current_hours

      unless options[:format] == "json"
        puts "\n--- Edit Summary ---"
        puts "  Date:     #{fields["started_at"] || entry["started_at"]}"
        puts "  Client:   #{fields["client_id"] ? maps[:clients][fields["client_id"].to_s] : current_client}"
        puts "  Project:  #{fields["project_id"] ? maps[:projects][fields["project_id"].to_s] : current_project}"
        puts "  Duration: #{new_hours}h"
        puts "  Note:     #{fields["note"] || entry["note"]}"
        puts "--------------------\n\n"
      end

      unless options[:yes]
        print "Save changes? (Y/n): "
        answer = $stdin.gets&.strip&.downcase
        abort("Cancelled.") if answer == "n"
      end

      result = Spinner.spin("Updating time entry") { Api.update_time_entry(entry_id, fields) }

      if options[:format] == "json"
        puts JSON.pretty_generate(result)
      else
        puts "Time entry #{entry_id} updated."
      end
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
        if options[:format] == "json"
          if cache["updated_at"]
            age = Time.now.to_i - cache["updated_at"]
            puts JSON.pretty_generate({
              "updated_at" => cache["updated_at"],
              "age_seconds" => age,
              "fresh" => age < 600,
              "clients" => (cache["clients_data"] || []).length,
              "projects" => (cache["projects_data"] || []).length,
              "services" => (cache["services"] || cache["services_data"] || {}).length
            })
          else
            puts JSON.pretty_generate({ "fresh" => false, "clients" => 0, "projects" => 0, "services" => 0 })
          end
          return
        end

        if cache["updated_at"]
          age = Time.now.to_i - cache["updated_at"]
          updated = Time.at(cache["updated_at"]).strftime("%Y-%m-%d %H:%M:%S")
          fresh = age < 600
          puts "Cache updated: #{updated}"
          puts "Age: #{age}s (#{fresh ? "fresh" : "stale"})"
          puts "Clients: #{(cache["clients_data"] || []).length}"
          puts "Projects: #{(cache["projects_data"] || []).length}"
          puts "Services: #{(cache["services"] || cache["services_data"] || {}).length}"
        else
          puts "No cache data."
        end
      else
        abort("Unknown cache subcommand: #{subcommand}. Use: refresh, clear, status")
      end
    end

    # --- help ---

    desc "help [COMMAND]", "Describe available commands or one specific command"
    def help(command = nil)
      if options[:format] == "json"
        puts JSON.pretty_generate(help_json)
        return
      end
      super
    end

    private

    def interactive?
      return false if options[:no_interactive]
      return true if options[:interactive]
      $stdin.tty?
    end

    def select_client(defaults)
      clients = Spinner.spin("Fetching clients") { Api.fetch_clients }

      if options[:client]
        match = clients.find { |c| display_name(c).downcase == options[:client].downcase }
        abort("Client not found: #{options[:client]}") unless match
        return match
      end

      abort("No clients found.") if clients.empty?

      unless interactive?
        # Non-interactive: auto-select if single, abort with list if multiple
        default_client = clients.find { |c| c["id"].to_i == defaults["client_id"].to_i }
        return default_client if default_client
        return clients.first if clients.length == 1
        names = clients.map { |c| display_name(c) }.join(", ")
        abort("Multiple clients found. Use --client to specify: #{names}")
      end

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

    def select_project(client_id, defaults)
      projects = Spinner.spin("Fetching projects") { Api.fetch_projects_for_client(client_id) }

      if options[:project]
        match = projects.find { |p| p["title"].downcase == options[:project].downcase }
        abort("Project not found: #{options[:project]}") unless match
        return match
      end

      return nil if projects.empty?

      unless interactive?
        # Non-interactive: auto-select if single, return nil if multiple (optional)
        default_project = projects.find { |p| p["id"].to_i == defaults["project_id"].to_i }
        return default_project if default_project
        return projects.first if projects.length == 1
        return nil
      end

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

    def select_service(defaults, project = nil)
      # Use project-scoped services if available, fall back to global
      services = if project && project["services"] && !project["services"].empty?
        project["services"]
      else
        Spinner.spin("Fetching services") { Api.fetch_services }
      end

      if options[:service]
        match = services.find { |s| s["name"].downcase == options[:service].downcase }
        abort("Service not found: #{options[:service]}") unless match
        return match
      end

      unless interactive?
        # Non-interactive: auto-select if single, use default if set, otherwise skip
        default_service = services.find { |s| s["id"].to_i == defaults["service_id"].to_i }
        return default_service if default_service
        return services.first if services.length == 1
        return nil
      end

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

    def pick_date
      return options[:date] if options[:date]

      today = Date.today.to_s
      return today unless interactive?

      print "\nDate [#{today}]: "
      input = $stdin.gets&.strip
      (input.nil? || input.empty?) ? today : input
    end

    def pick_duration
      return options[:duration] if options[:duration]

      abort("Missing required flag: --duration") unless interactive?

      print "\nDuration (hours): "
      input = $stdin.gets&.strip
      abort("Duration is required.") if input.nil? || input.empty?
      input.to_f
    end

    def pick_note
      return options[:note] if options[:note]

      abort("Missing required flag: --note") unless interactive?

      print "\nNote: "
      input = $stdin.gets&.strip
      abort("Note is required.") if input.nil? || input.empty?
      input
    end

    def print_table(headers, rows, wrap_col: nil)
      widths = headers.each_with_index.map do |h, i|
        [h.length, *rows.map { |r| r[i].to_s.length }].max
      end

      # Word-wrap a specific column if it would exceed terminal width
      if wrap_col
        term_width = IO.console&.winsize&.last || ENV["COLUMNS"]&.to_i || 120
        fixed_width = widths.each_with_index.sum { |w, i| i == wrap_col ? 0 : w } + (widths.length - 1) * 2
        max_wrap = term_width - fixed_width
        max_wrap = [max_wrap, 20].max
        widths[wrap_col] = [widths[wrap_col], max_wrap].min
      end

      fmt = widths.map { |w| "%-#{w}s" }.join("  ")
      puts fmt % headers
      puts widths.map { |w| "-" * w }.join("  ")

      rows.each do |r|
        if wrap_col && r[wrap_col].to_s.length > widths[wrap_col]
          lines = word_wrap(r[wrap_col].to_s, widths[wrap_col])
          padded = widths.each_with_index.map { |w, i| i == wrap_col ? "" : " " * w }
          pad_fmt = padded.each_with_index.map { |p, i| i == wrap_col ? "%s" : "%-#{widths[i]}s" }.join("  ")
          lines.each_with_index do |line, li|
            if li == 0
              row = r.dup
              row[wrap_col] = line
              puts fmt % row
            else
              blank = padded.dup
              blank[wrap_col] = line
              puts pad_fmt % blank
            end
          end
        else
          puts fmt % r
        end
      end
    end

    def word_wrap(text, width)
      lines = []
      remaining = text
      while remaining.length > width
        break_at = remaining.rindex(" ", width) || width
        lines << remaining[0...break_at]
        remaining = remaining[break_at..].lstrip
      end
      lines << remaining unless remaining.empty?
      lines
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

    def build_status_data(from, to, entries, maps)
      entry_data = entries.map do |e|
        {
          "id" => e["id"],
          "client" => maps[:clients][e["client_id"].to_s] || e["client_id"].to_s,
          "project" => maps[:projects][e["project_id"].to_s] || "-",
          "duration" => e["duration"],
          "hours" => (e["duration"].to_i / 3600.0).round(2),
          "note" => e["note"],
          "started_at" => e["started_at"]
        }
      end
      total = entries.sum { |e| e["duration"].to_i } / 3600.0
      { "from" => from, "to" => to, "entries" => entry_data, "total_hours" => total.round(2) }
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
      # FreshBooks API replaces the entry — always include all current fields
      fields = {
        "started_at" => entry["started_at"],
        "is_logged" => entry["is_logged"] || true,
        "duration" => entry["duration"],
        "note" => entry["note"],
        "client_id" => entry["client_id"],
        "project_id" => entry["project_id"],
        "service_id" => entry["service_id"]
      }

      if scripted
        fields["duration"] = (options[:duration] * 3600).to_i if options[:duration]
        fields["note"] = options[:note] if options[:note]
        fields["started_at"] = normalize_datetime(options[:date]) if options[:date]

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

    def normalize_datetime(date_str)
      return date_str if date_str.include?("T")
      "#{date_str}T00:00:00Z"
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
        global_flags: {
          "--no-interactive" => "Disable interactive prompts (auto-detected when not a TTY)",
          "--format json"    => "Output format: json (available on all commands)",
          "--dry-run"        => "Simulate command without making network calls (writes skipped)"
        },
        commands: {
          auth: {
            description: "Authenticate with FreshBooks via OAuth2",
            usage: "fb auth [SUBCOMMAND]",
            interactive: "Interactive when no subcommand; subcommands are non-interactive",
            subcommands: {
              "setup" => "Save OAuth credentials from env vars: FRESHBOOKS_CLIENT_ID, FRESHBOOKS_CLIENT_SECRET (or ~/.fb/.env)",
              "url" => "Print the OAuth authorization URL",
              "callback" => "Exchange OAuth code: fb auth callback REDIRECT_URL",
              "status" => "Show current auth state (config, tokens, business)"
            },
            flags: {}
          },
          business: {
            description: "List or select a business",
            usage: "fb business [--select ID]",
            interactive: "Interactive with --select (no value); non-interactive with --select ID",
            flags: {
              "--select ID" => "Set active business by ID",
              "--select" => "Interactive business picker (no value)"
            }
          },
          log: {
            description: "Log a time entry",
            usage: "fb log",
            interactive: "Prompts for missing fields when interactive; requires --duration and --note when non-interactive",
            flags: {
              "--client" => "Client name (required non-interactive if multiple clients, auto-selected if single)",
              "--project" => "Project name (optional, auto-selected if single)",
              "--service" => "Service name (optional)",
              "--duration" => "Duration in hours, e.g. 2.5 (required non-interactive)",
              "--note" => "Work description (required non-interactive)",
              "--date" => "Date YYYY-MM-DD (defaults to today)",
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
              "--year" => "Year (defaults to current)"
            }
          },
          clients: {
            description: "List all clients",
            usage: "fb clients"
          },
          projects: {
            description: "List all projects",
            usage: "fb projects",
            flags: {
              "--client" => "Filter by client name"
            }
          },
          services: {
            description: "List all services",
            usage: "fb services"
          },
          status: {
            description: "Show hours summary for today, this week, and this month",
            usage: "fb status"
          },
          delete: {
            description: "Delete a time entry",
            usage: "fb delete --id ID --yes",
            interactive: "Interactive picker when no --id; requires --id when non-interactive",
            flags: {
              "--id" => "Time entry ID (required non-interactive)",
              "--yes" => "Skip confirmation prompt"
            }
          },
          edit: {
            description: "Edit a time entry",
            usage: "fb edit --id ID [--duration H] [--note TEXT] --yes",
            interactive: "Interactive picker and field editor when no --id; requires --id when non-interactive",
            flags: {
              "--id" => "Time entry ID (required non-interactive)",
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
            usage: "fb help [COMMAND]"
          }
        }
      }
    end
  end
end
