# frozen_string_literal: true

require "httparty"
require "json"

module FB
  class Api
    BASE = "https://api.freshbooks.com"

    class << self
      def headers
        token = Auth.valid_access_token
        {
          "Authorization" => "Bearer #{token}",
          "Content-Type" => "application/json"
        }
      end

      def config
        @config = nil
        @config = Auth.require_config
      end

      def business_id
        c = config
        unless c["business_id"]
          c = Auth.require_business(c)
        end
        c["business_id"]
      end

      def account_id
        c = config
        unless c["account_id"]
          c = Auth.require_business(c)
        end
        c["account_id"]
      end

      # --- Paginated fetch ---

      def fetch_all_pages(url, result_key, params: {})
        return [] if Thread.current[:fb_dry_run]

        page = 1
        all_items = []

        loop do
          response = HTTParty.get(url, {
            headers: headers,
            query: params.merge(page: page, per_page: 100)
          })

          unless response.success?
            body = response.parsed_response
            msg = extract_error(body) || response.body
            abort("API error: #{msg}")
          end

          data = response.parsed_response
          items = dig_results(data, result_key)
          break if items.nil? || items.empty?

          all_items.concat(items)

          meta = dig_meta(data)
          break if meta.nil?
          break if page >= meta["pages"].to_i

          page += 1
        end

        all_items
      end

      # --- Cache helpers ---

      def cache_fresh?
        cache = Auth.load_cache
        cache["updated_at"] && (Time.now.to_i - cache["updated_at"]) < 600
      end

      def cached_data(key)
        return Auth.load_cache[key] if Thread.current[:fb_dry_run]

        cache = Auth.load_cache
        return nil unless cache["updated_at"] && (Time.now.to_i - cache["updated_at"]) < 600
        cache[key]
      end

      def update_cache(key, data)
        cache = Auth.load_cache
        cache["updated_at"] = Time.now.to_i
        cache[key] = data
        Auth.save_cache(cache)
      end

      # --- Clients ---

      def fetch_clients(force: false)
        unless force
          cached = cached_data("clients_data")
          return cached if cached
        end

        url = "#{BASE}/accounting/account/#{account_id}/users/clients"
        results = fetch_all_pages(url, "clients")
        update_cache("clients_data", results)
        results
      end

      # --- Projects ---

      def fetch_projects(force: false)
        unless force
          cached = cached_data("projects_data")
          return cached if cached
        end

        url = "#{BASE}/projects/business/#{business_id}/projects"
        results = fetch_all_pages(url, "projects")
        update_cache("projects_data", results)
        results
      end

      def fetch_projects_for_client(client_id)
        all = fetch_projects
        all.select { |p| p["client_id"].to_i == client_id.to_i }
      end

      # --- Services ---

      def fetch_services(force: false)
        return (Auth.load_cache["services_data"] || []) if Thread.current[:fb_dry_run]

        unless force
          cached = cached_data("services_data")
          return cached if cached
        end

        url = "#{BASE}/comments/business/#{business_id}/services"
        response = HTTParty.get(url, { headers: headers })

        unless response.success?
          body = response.parsed_response
          msg = extract_error(body) || response.body
          abort("API error: #{msg}")
        end

        data = response.parsed_response
        services_hash = data.dig("result", "services") || {}
        results = services_hash.values
        update_cache("services_data", results)
        results
      end

      # --- Time Entries ---

      def fetch_time_entries(started_from: nil, started_to: nil)
        url = "#{BASE}/timetracking/business/#{business_id}/time_entries"
        params = {}
        params["started_from"] = "#{started_from}T00:00:00Z" if started_from
        params["started_to"] = "#{started_to}T23:59:59Z" if started_to
        fetch_all_pages(url, "time_entries", params: params)
      end

      def fetch_time_entry(entry_id)
        if Thread.current[:fb_dry_run]
          return {
            "id" => entry_id,
            "duration" => 3600,
            "note" => "(dry run - entry #{entry_id})",
            "started_at" => "#{Date.today}T00:00:00Z",
            "is_logged" => true
          }
        end

        url = "#{BASE}/timetracking/business/#{business_id}/time_entries/#{entry_id}"
        response = HTTParty.get(url, { headers: headers })

        unless response.success?
          body = response.parsed_response
          msg = extract_error(body) || response.body
          abort("API error: #{msg}")
        end

        data = response.parsed_response
        data.dig("result", "time_entry") || data.dig("time_entry")
      end

      def create_time_entry(entry)
        if Thread.current[:fb_dry_run]
          return {
            "_dry_run" => { "simulated" => true, "payload_sent" => entry },
            "result" => { "time_entry" => entry.merge("id" => 0) }
          }
        end

        url = "#{BASE}/timetracking/business/#{business_id}/time_entries"
        body = { time_entry: entry }

        response = HTTParty.post(url, {
          headers: headers,
          body: body.to_json
        })

        unless response.success?
          body = response.parsed_response
          msg = extract_error(body) || response.body
          abort("API error: #{msg}")
        end

        response.parsed_response
      end

      def update_time_entry(entry_id, fields)
        if Thread.current[:fb_dry_run]
          return {
            "_dry_run" => { "simulated" => true, "payload_sent" => fields },
            "result" => { "time_entry" => fields.merge("id" => entry_id) }
          }
        end

        url = "#{BASE}/timetracking/business/#{business_id}/time_entries/#{entry_id}"
        body = { time_entry: fields }

        response = HTTParty.put(url, {
          headers: headers,
          body: body.to_json
        })

        unless response.success?
          body = response.parsed_response
          msg = extract_error(body) || response.body
          abort("API error: #{msg}")
        end

        response.parsed_response
      end

      def delete_time_entry(entry_id)
        return true if Thread.current[:fb_dry_run]

        url = "#{BASE}/timetracking/business/#{business_id}/time_entries/#{entry_id}"

        response = HTTParty.delete(url, { headers: headers })

        unless response.success?
          body = response.parsed_response
          msg = extract_error(body) || response.body
          abort("API error: #{msg}")
        end

        true
      end

      # --- Name Resolution (for entries display) ---

      def build_name_maps
        cache = Auth.load_cache
        now = Time.now.to_i

        if cache["updated_at"] && (now - cache["updated_at"]) < 600 &&
           cache["clients"] && !cache["clients"].empty?
          return {
            clients: (cache["clients"] || {}),
            projects: (cache["projects"] || {}),
            services: (cache["services"] || {})
          }
        end

        clients = fetch_clients(force: true)
        projects = fetch_projects(force: true)
        services = fetch_services(force: true)

        client_map = {}
        clients.each do |c|
          name = c["organization"]
          name = "#{c["fname"]} #{c["lname"]}" if name.nil? || name.empty?
          client_map[c["id"].to_s] = name
        end

        project_map = {}
        projects.each do |p|
          project_map[p["id"].to_s] = p["title"]
        end

        service_map = {}
        services.each do |s|
          service_map[s["id"].to_s] = s["name"]
        end

        # Also collect services embedded in projects
        projects.each do |p|
          (p["services"] || []).each do |s|
            service_map[s["id"].to_s] ||= s["name"]
          end
        end

        cache = Auth.load_cache
        cache["updated_at"] = now
        cache["clients"] = client_map
        cache["projects"] = project_map
        cache["services"] = service_map
        Auth.save_cache(cache)

        { clients: client_map, projects: project_map, services: service_map }
      end

      private

      def extract_error(body)
        return nil unless body.is_a?(Hash)
        body["error_description"] ||
          body.dig("response", "errors", 0, "message") ||
          body.dig("error") ||
          body.dig("message")
      end

      def dig_results(data, key)
        data.dig("result", key) ||
          data.dig("response", "result", key) ||
          data.dig(key)
      end

      def dig_meta(data)
        data.dig("result", "meta") ||
          data.dig("response", "result", "meta") ||
          data.dig("meta")
      end
    end
  end
end
