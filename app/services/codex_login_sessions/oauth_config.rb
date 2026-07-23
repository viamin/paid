# frozen_string_literal: true

module CodexLoginSessions
  # External OAuth configuration for the Connect Codex device-code flow
  # (RDR-041 / #2962). The endpoints are OpenAI's public auth endpoints; the
  # client id must be supplied by the operator via env so Paid never ships a
  # baked-in provider client id. This keeps provider-specific OAuth details
  # configurable rather than scattered and hardcoded.
  class OAuthConfig
    DEFAULT_DEVICE_URL = "https://auth.openai.com/oauth/device/code"
    DEFAULT_TOKEN_URL = "https://auth.openai.com/oauth/token"
    DEFAULT_SCOPES = "openai/subscription offline_access"

    attr_reader :client_id, :device_url, :token_url, :scopes

    def initialize(client_id:, device_url:, token_url:, scopes:)
      @client_id = client_id
      @device_url = device_url
      @token_url = token_url
      @scopes = scopes
    end

    def configured?
      client_id.present? && device_url.present? && token_url.present?
    end

    def self.load(env: ENV)
      new(
        client_id: env["CODEX_OAUTH_CLIENT_ID"].presence,
        device_url: env["CODEX_OAUTH_DEVICE_URL"].presence || DEFAULT_DEVICE_URL,
        token_url: env["CODEX_OAUTH_TOKEN_URL"].presence || DEFAULT_TOKEN_URL,
        scopes: env["CODEX_OAUTH_SCOPES"].presence || DEFAULT_SCOPES
      )
    end
  end
end
