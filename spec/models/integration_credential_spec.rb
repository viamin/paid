# frozen_string_literal: true

require "rails_helper"

RSpec.describe IntegrationCredential do
  describe "validations" do
    it "assigns category from the selected service" do
      credential = build(:integration_credential, service_key: "jira", category: nil)

      credential.validate

      expect(credential.category).to eq("issue_tracking")
    end

    it "rejects unsupported services" do
      credential = build(:integration_credential, service_key: "unknown")

      expect(credential).not_to be_valid
      expect(credential.errors[:service_key]).to include("is not supported")
    end

    it "rejects unsupported auth kinds for signing credentials" do
      credential = build(:integration_credential, :github_signing, auth_kind: "api_key")

      expect(credential).not_to be_valid
      expect(credential.errors[:auth_kind]).to include("is not supported for GitHub Signing")
    end
  end
end
