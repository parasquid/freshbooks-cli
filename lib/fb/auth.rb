# frozen_string_literal: true

require "httparty"
require "json"
require "uri"
require "fileutils"

module FB
  class Auth
    TOKEN_URL = "https://api.freshbooks.com/auth/oauth/token"
    AUTH_URL = "https://auth.freshbooks.com/oauth/authorize"
    ME_URL = "https://api.freshbooks.com/auth/api/v1/users/me"
    REDIRECT_URI = "https://localhost"

    class << self
      def data_dir
        @data_dir ||= File.join(Dir.home, ".fb")
      end

      def data_dir=(path)
        @data_dir = path
      end

      def config_path
        File.join(data_dir, "config.json")
      end

      def tokens_path
        File.join(data_dir, "tokens.json")
      end

      def defaults_path
        File.join(data_dir, "defaults.json")
      end

      def cache_path
        File.join(data_dir, "cache.json")
      end

      def ensure_data_dir
        FileUtils.mkdir_p(data_dir)
      end

      # --- Config ---

      def load_config
        return nil unless File.exist?(config_path)
        contents = File.read(config_path).strip
        return nil if contents.empty?
        config = JSON.parse(contents)
        return nil unless config["client_id"] && config["client_secret"]
        config
      rescue JSON::ParserError
        nil
      end

      def save_config(config)
        ensure_data_dir
        File.write(config_path, JSON.pretty_generate(config) + "\n")
      end

      def setup_config
        puts "Welcome to FreshBooks CLI setup!\n\n"
        puts "You need a FreshBooks Developer App. Create one at:"
        puts "  https://my.freshbooks.com/#/developer\n\n"
        puts "Set the redirect URI to: #{REDIRECT_URI}\n\n"

        print "Client ID: "
        client_id = $stdin.gets&.strip
        abort("Aborted.") if client_id.nil? || client_id.empty?

        print "Client Secret: "
        client_secret = $stdin.gets&.strip
        abort("Aborted.") if client_secret.nil? || client_secret.empty?

        config = { "client_id" => client_id, "client_secret" => client_secret }
        save_config(config)
        puts "\nConfig saved to #{config_path}"
        config
      end

      def require_config
        config = load_config
        return config if config

        puts "No config found. Let's set up FreshBooks CLI.\n\n"
        setup_config
      end

      # --- Tokens ---

      def load_tokens
        return nil unless File.exist?(tokens_path)
        JSON.parse(File.read(tokens_path))
      end

      def save_tokens(tokens)
        ensure_data_dir
        File.write(tokens_path, JSON.pretty_generate(tokens) + "\n")
      end

      def token_expired?(tokens)
        return true unless tokens
        created = tokens["created_at"] || 0
        expires_in = tokens["expires_in"] || 0
        Time.now.to_i >= (created + expires_in - 60)
      end

      def refresh_token!(config, tokens)
        response = HTTParty.post(TOKEN_URL, {
          headers: { "Content-Type" => "application/json" },
          body: {
            grant_type: "refresh_token",
            client_id: config["client_id"],
            client_secret: config["client_secret"],
            redirect_uri: REDIRECT_URI,
            refresh_token: tokens["refresh_token"]
          }.to_json
        })

        unless response.success?
          body = response.parsed_response
          msg = body.is_a?(Hash) ? (body["error_description"] || body["error"] || response.body) : response.body
          abort("Token refresh failed: #{msg}\nPlease re-run: fb auth")
        end

        data = response.parsed_response
        new_tokens = {
          "access_token" => data["access_token"],
          "refresh_token" => data["refresh_token"],
          "expires_in" => data["expires_in"],
          "created_at" => Time.now.to_i
        }
        save_tokens(new_tokens)
        new_tokens
      end

      def valid_access_token
        config = require_config
        tokens = load_tokens

        unless tokens
          abort("Not authenticated. Run: fb auth")
        end

        if token_expired?(tokens)
          puts "Token expired, refreshing..."
          tokens = refresh_token!(config, tokens)
        end

        tokens["access_token"]
      end

      # --- OAuth Flow ---

      def authorize(config)
        url = "#{AUTH_URL}?client_id=#{config["client_id"]}&response_type=code&redirect_uri=#{URI.encode_www_form_component(REDIRECT_URI)}"

        puts "Open this URL in your browser:\n\n"
        puts "  #{url}\n\n"
        puts "After authorizing, you'll be redirected to a URL that fails to load."
        puts "Copy the full URL from your browser's address bar and paste it here.\n\n"

        print "Redirect URL: "
        redirect_url = $stdin.gets&.strip
        abort("Aborted.") if redirect_url.nil? || redirect_url.empty?

        uri = URI.parse(redirect_url)
        params = URI.decode_www_form(uri.query || "").to_h
        code = params["code"]

        abort("Could not find 'code' parameter in the URL.") unless code

        exchange_code(config, code)
      end

      def exchange_code(config, code)
        response = HTTParty.post(TOKEN_URL, {
          headers: { "Content-Type" => "application/json" },
          body: {
            grant_type: "authorization_code",
            client_id: config["client_id"],
            client_secret: config["client_secret"],
            redirect_uri: REDIRECT_URI,
            code: code
          }.to_json
        })

        unless response.success?
          body = response.parsed_response
          msg = body.is_a?(Hash) ? (body["error_description"] || body["error"] || response.body) : response.body
          abort("Token exchange failed: #{msg}")
        end

        data = response.parsed_response
        tokens = {
          "access_token" => data["access_token"],
          "refresh_token" => data["refresh_token"],
          "expires_in" => data["expires_in"],
          "created_at" => Time.now.to_i
        }
        save_tokens(tokens)
        puts "Authentication successful!"
        tokens
      end

      # --- Business Discovery ---

      def fetch_identity(access_token)
        response = HTTParty.get(ME_URL, {
          headers: { "Authorization" => "Bearer #{access_token}" }
        })

        unless response.success?
          abort("Failed to fetch user identity: #{response.body}")
        end

        response.parsed_response["response"]
      end

      def discover_business(access_token, config)
        identity = fetch_identity(access_token)
        memberships = identity.dig("business_memberships") || []
        businesses = memberships.select { |m| m.dig("business", "account_id") }

        if businesses.empty?
          abort("No business memberships found on your FreshBooks account.")
        end

        selected = if businesses.length == 1
          businesses.first
        else
          puts "\nMultiple businesses found:\n\n"
          businesses.each_with_index do |m, i|
            biz = m["business"]
            puts "  #{i + 1}. #{biz["name"]} (ID: #{biz["id"]})"
          end
          print "\nSelect a business (1-#{businesses.length}): "
          choice = $stdin.gets&.strip&.to_i || 1
          choice = 1 if choice < 1 || choice > businesses.length
          businesses[choice - 1]
        end

        biz = selected["business"]
        config["business_id"] = biz["id"]
        config["account_id"] = biz["account_id"]
        save_config(config)

        puts "Business: #{biz["name"]}"
        puts "  business_id: #{biz["id"]}"
        puts "  account_id: #{biz["account_id"]}"
        config
      end

      # --- Defaults ---

      def load_defaults
        return {} unless File.exist?(defaults_path)
        JSON.parse(File.read(defaults_path))
      rescue JSON::ParserError
        {}
      end

      def save_defaults(defaults)
        ensure_data_dir
        File.write(defaults_path, JSON.pretty_generate(defaults) + "\n")
      end

      # --- Cache ---

      def load_cache
        return {} unless File.exist?(cache_path)
        JSON.parse(File.read(cache_path))
      rescue JSON::ParserError
        {}
      end

      def save_cache(cache)
        ensure_data_dir
        File.write(cache_path, JSON.pretty_generate(cache) + "\n")
      end
    end
  end
end
