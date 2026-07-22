# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module CodexLoginSessions
  # Thin HTTP client for the OpenAI device-code OAuth flow (RDR-041 / #2962).
  # Wraps the two endpoints (device authorization + token polling) behind a
  # stubbable transport so the device flow can be exercised in tests without
  # real network calls.
  class OAuthClient
    DeviceResponse = Data.define(:device_code, :user_code, :verification_uri, :expires_in, :interval) do
      def self.from_payload(payload)
        new(
          device_code: payload["device_code"],
          user_code: payload["user_code"],
          verification_uri: payload["verification_uri_complete"] || payload["verification_uri"],
          expires_in: payload["expires_in"].to_i,
          interval: payload["interval"].to_i
        )
      end
    end

    # status: :success | :pending | :slow_down | :denied | :expired | :error
    TokenResponse = Data.define(:status, :tokens, :error)

    def initialize(config: OAuthConfig.load, transport: nil)
      @config = config.respond_to?(:call) ? config.call : config
      @transport = transport || method(:net_http_post)
    end

    def request_device_code
      raise ConfigurationError, "Connect Codex OAuth is not configured (set CODEX_OAUTH_CLIENT_ID)" unless @config.configured?

      payload = post(@config.device_url, "client_id" => @config.client_id, "scope" => @config.scopes)
      DeviceResponse.from_payload(payload)
    rescue Net::HTTPError, Net::OpenTimeout, Errno::ECONNREFUSED => e
      raise DeviceRequestError, "Codex device-code request failed: #{e.message}"
    end

    def poll_token(device_code)
      raise ConfigurationError, "Connect Codex OAuth is not configured (set CODEX_OAUTH_CLIENT_ID)" unless @config.configured?

      payload = post(@config.token_url,
        "grant_type" => "urn:ietf:params:oauth:grant-type:device_code",
        "client_id" => @config.client_id,
        "device_code" => device_code)

      TokenResponse.new(status: token_status(payload), tokens: success_tokens(payload), error: payload["error"])
    rescue Net::HTTPError, Net::OpenTimeout, Errno::ECONNREFUSED => e
      TokenResponse.new(status: :error, tokens: nil, error: "token_request_failed: #{e.message}")
    end

    class ConfigurationError < StandardError; end
    class DeviceRequestError < StandardError; end

    private

    def post(url, params)
      body = @transport.call(url, params)
      JSON.parse(body.to_s)
    rescue JSON::ParserError => e
      raise Net::HTTPError.new("invalid JSON response: #{e.message}", nil)
    end

    def token_status(payload)
      return :success if payload["access_token"].present?

      case payload["error"]
      when "authorization_pending" then :pending
      when "slow_down" then :slow_down
      when "access_denied", "expired_token" then :denied
      else :error
      end
    end

    def success_tokens(payload)
      return nil unless payload["access_token"].present?

      {
        "id_token" => payload["id_token"],
        "access_token" => payload["access_token"],
        "refresh_token" => payload["refresh_token"],
        "account_id" => payload["account_id"] || payload.dig("id_token")
      }.compact
    end

    def net_http_post(url, params)
      uri = URI(url)
      response = Net::HTTP.post_form(uri, params)
      raise Net::HTTPError.new("OAuth endpoint returned #{response.code}", response) unless response.is_a?(Net::HTTPSuccess)

      response.body
    end
  end
end
