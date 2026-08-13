# frozen_string_literal: true

require "rails_helper"

RSpec.describe CodexLoginSessions::OAuthConfig, :no_db do
  describe ".load" do
    it "uses OpenAI defaults when no env is set" do
      config = described_class.load(env: {})

      expect(config.device_url).to eq("https://auth.openai.com/oauth/device/code")
      expect(config.token_url).to eq("https://auth.openai.com/oauth/token")
      expect(config.scopes).to eq("openai/subscription offline_access")
      expect(config).not_to be_configured
    end

    it "reads the client id and overrides from env" do
      config = described_class.load(env: {
        "CODEX_OAUTH_CLIENT_ID" => "cid-123",
        "CODEX_OAUTH_DEVICE_URL" => "https://device.example/code",
        "CODEX_OAUTH_TOKEN_URL" => "https://token.example/token",
        "CODEX_OAUTH_SCOPES" => "openid email"
      })

      expect(config.client_id).to eq("cid-123")
      expect(config.device_url).to eq("https://device.example/code")
      expect(config.token_url).to eq("https://token.example/token")
      expect(config.scopes).to eq("openid email")
      expect(config).to be_configured
    end

    it "treats a blank client id as unconfigured" do
      config = described_class.load(env: { "CODEX_OAUTH_CLIENT_ID" => "  " })

      expect(config.client_id).to be_nil
      expect(config).not_to be_configured
    end
  end
end
