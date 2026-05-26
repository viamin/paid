# frozen_string_literal: true

require "faraday"

module Github
  class ReviewBotInstallationToken
    APP_ID = "3340381"
    APP_SLUG = "paid-code-reviewer"
    BOT_LOGIN = "#{APP_SLUG}[bot]"
    CREDENTIAL_KEY = :"paid-code-reviewer-private-key"
    API_BASE_URL = "https://api.github.com"

    class Error < StandardError; end
    class ConfigurationError < Error; end

    def self.app_id
      ENV["PAID_CODE_REVIEWER_APP_ID"].presence || APP_ID
    end

    def self.private_key
      ENV["PAID_CODE_REVIEWER_PRIVATE_KEY"].presence ||
        Rails.application.credentials.dig(CREDENTIAL_KEY).presence
    end

    def self.configured?
      app_id.present? && private_key.present? && private_key_parseable?
    end

    def self.private_key_parseable?
      Github::AppJwt.private_key_parseable?(private_key)
    end

    def self.bot_logins
      [ APP_SLUG, BOT_LOGIN ].freeze
    end

    def initialize(repo_full_name:)
      @repo_full_name = repo_full_name
    end

    def fetch
      validate_configuration!

      installation_id = installation_response.fetch("id")
      token_response = post("/app/installations/#{installation_id}/access_tokens")

      token_response.fetch("token")
    rescue KeyError => e
      raise Error, "GitHub review bot token response missing #{e.key}"
    end

    private

    attr_reader :repo_full_name

    def validate_configuration!
      return if self.class.configured?

      raise ConfigurationError, "Paid review bot GitHub App is not configured"
    end

    def installation_response
      owner, repo = repo_full_name.split("/", 2)
      get("/repos/#{owner}/#{repo}/installation")
    end

    def get(path)
      response = connection.get(path) do |request|
        app_headers.each { |key, value| request.headers[key] = value }
      end

      parse_response(response)
    end

    def post(path)
      response = connection.post(path) do |request|
        app_headers.each { |key, value| request.headers[key] = value }
        request.headers["Content-Type"] = "application/json"
        request.body = "{}"
      end

      parse_response(response)
    end

    def app_headers
      {
        "Accept" => "application/vnd.github+json",
        "Authorization" => "Bearer #{app_jwt}"
      }
    end

    def app_jwt
      Github::AppJwt.sign(app_id: self.class.app_id, private_key: self.class.private_key)
    end

    def connection
      @connection ||= Faraday.new(url: API_BASE_URL) do |faraday|
        faraday.options.timeout = 30
        faraday.options.open_timeout = 10
      end
    end

    def parse_response(response)
      body = JSON.parse(response.body)
      return body if response.success?

      message = body.is_a?(Hash) ? body["message"] : response.body
      raise Error, "GitHub review bot request failed (status #{response.status}): #{message}"
    rescue JSON::ParserError
      raise Error, "GitHub review bot request returned invalid JSON (status #{response.status})"
    end
  end
end
