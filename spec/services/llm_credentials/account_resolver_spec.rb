# frozen_string_literal: true

require "rails_helper"

RSpec.describe LlmCredentials::AccountResolver do
  describe ".call" do
    it "returns the Claude OAuth access token when the active credential stores native json" do
      account = create(:account)
      create(:integration_credential,
        account: account,
        service_key: "claude",
        auth_kind: "oauth_token",
        secret: {
          "claudeAiOauth" => {
            "accessToken" => "access-token",
            "refreshToken" => "refresh-token"
          }
        }.to_json
      )

      result = described_class.call(account: account, runner_key: "claude")

      expect(result.integration_credential).to be_present
      expect(result.api_secret).to eq("access-token")
    end
  end
end
