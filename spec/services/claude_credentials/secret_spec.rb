# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClaudeCredentials::Secret do
  describe ".parse" do
    it "parses a long-lived oauth token string" do
      parsed = described_class.parse("sk-ant-oat01-managed-token")

      expect(parsed).to be_long_lived_token
      expect(parsed.oauth_token).to eq("sk-ant-oat01-managed-token")
      expect(parsed.credentials_json).to be_nil
    end

    it "parses native Claude credentials json" do
      expiry = 2.hours.from_now.iso8601
      parsed = described_class.parse(
        JSON.generate(
          "claudeAiOauth" => {
            "accessToken" => "access-token",
            "refreshToken" => "refresh-token",
            "expiresAt" => expiry,
            "subscriptionType" => "pro",
            "scopes" => %w[user:profile user:inference]
          }
        )
      )

      expect(parsed).to be_native_credentials_json
      expect(parsed.oauth_token).to eq("access-token")
      expect(parsed.refresh_token).to eq("refresh-token")
      expect(parsed.subscription_type).to eq("pro")
      expect(parsed.scopes).to include("user:profile")
      expect(parsed.expires_at.iso8601).to eq(expiry)
    end
  end
end
