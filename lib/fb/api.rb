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
        config["business_id"] || abort("No business_id in config. Run: fb auth")
      end

      def account_id
        config["account_id"] || abort("No account_id in config. Run: fb auth")
      end

      # --- Paginated fetch ---

      def fetch_all_pages(url, result_key, params: {})
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

      # --- Clients ---

      def fetch_clients
        url = "#{BASE}/accounting/account/#{account_id}/users/clients"
        fetch_all_pages(url, "clients")
      end

      # --- Projects ---

      def fetch_projects
        url = "#{BASE}/projects/business/#{business_id}/projects"
        fetch_all_pages(url, "projects")
      end

      def fetch_projects_for_client(client_id)
        all = fetch_projects
        all.select { |p| p["client_id"].to_i == client_id.to_i }
      end

      # --- Services ---

      def fetch_services
        url = "#{BASE}/comments/business/#{business_id}/services"
        response = HTTParty.get(url, { headers: headers })

        unless response.success?
          body = response.parsed_response
          msg = extract_error(body) || response.body
          abort("API error: #{msg}")
        end

        data = response.parsed_response
        services_hash = data.dig("result", "services") || {}
        services_hash.values
      end

      # --- Time Entries ---

      def fetch_time_entries(started_from:, started_to:)
        url = "#{BASE}/timetracking/business/#{business_id}/time_entries"
        params = {
          "search[started_from]" => started_from,
          "search[started_to]" => started_to
        }
        fetch_all_pages(url, "time_entries", params: params)
      end

      def create_time_entry(entry)
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

      # --- Name Resolution (for entries display) ---

      def build_name_maps
        cache = Auth.load_cache
        now = Time.now.to_i

        if cache["updated_at"] && (now - cache["updated_at"]) < 600
          return {
            clients: (cache["clients"] || {}),
            projects: (cache["projects"] || {})
          }
        end

        clients = fetch_clients
        projects = fetch_projects

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

        cache_data = {
          "updated_at" => now,
          "clients" => client_map,
          "projects" => project_map
        }
        Auth.save_cache(cache_data)

        { clients: client_map, projects: project_map }
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
