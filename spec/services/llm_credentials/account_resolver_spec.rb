# frozen_string_literal: true

require "rails_helper"

RSpec.describe LlmCredentials::AccountResolver do
  describe ".call" do
    it "returns the active integration credential for the requested runner key" do
      account = create(:account)
      credential = create(:integration_credential,
        account: account,
        service_key: "claude",
        auth_kind: "api_key",
        secret: "sk-ant-account-managed"
      )

      result = described_class.call(account: account, runner_key: "claude")

      expect(result.integration_credential).to eq(credential)
      expect(result.api_secret).to eq("sk-ant-account-managed")
    end
  end
end
