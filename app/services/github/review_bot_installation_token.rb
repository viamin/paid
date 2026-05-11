# frozen_string_literal: true

require "base64"
require "faraday"
require "openssl"

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

    # Verifies the configured value actually parses as an RSA key. Catches the
    # common misconfiguration where the credential is set to a non-PEM value
    # (e.g. an OpenSSH private key) — in which case the credential passes a
    # presence check but every JWT mint fails at runtime with a 503 from the
    # proxy. Memoized per key string so a rotated credential is re-validated
    # without a process restart.
    def self.private_key_parseable?
      key = private_key.to_s
      return false if key.empty?
      return @private_key_parseable if defined?(@private_key_parse_cache_key) &&
                                      @private_key_parse_cache_key == key

      @private_key_parse_cache_key = key
      @private_key_parseable = begin
        OpenSSL::PKey::RSA.new(key.gsub('\n', "\n"))
        true
      rescue OpenSSL::PKey::RSAError
        false
      end
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
      now = Time.current.to_i
      payload = {
        iat: now - 60,
        exp: now + (9 * 60),
        iss: self.class.app_id
      }

      segments = [
        jwt_segment(alg: "RS256", typ: "JWT"),
        jwt_segment(payload)
      ]

      signature = rsa_private_key.sign(OpenSSL::Digest::SHA256.new, segments.join("."))
      "#{segments.join(".")}.#{Base64.urlsafe_encode64(signature, padding: false)}"
    end

    def jwt_segment(payload)
      Base64.urlsafe_encode64(payload.to_json, padding: false)
    end

    def rsa_private_key
      @rsa_private_key ||= OpenSSL::PKey::RSA.new(normalized_private_key)
    rescue OpenSSL::PKey::RSAError => e
      raise ConfigurationError, "Paid review bot private key is invalid: #{e.message}"
    end

    def normalized_private_key
      self.class.private_key.to_s.gsub('\n', "\n")
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
