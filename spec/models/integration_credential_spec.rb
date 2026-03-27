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

  describe ".active" do
    it "excludes revoked credentials" do
      active = create(:integration_credential)
      create(:integration_credential, :revoked)

      expect(described_class.active).to contain_exactly(active)
    end

    it "excludes expired credentials" do
      active = create(:integration_credential)
      create(:integration_credential, :expired)

      expect(described_class.active).to contain_exactly(active)
    end

    it "includes credentials with future expiration" do
      credential = create(:integration_credential, expires_at: 1.day.from_now)

      expect(described_class.active).to include(credential)
    end
  end

  describe "#expired?" do
    it "returns false when expires_at is nil" do
      credential = build(:integration_credential, expires_at: nil)

      expect(credential).not_to be_expired
    end

    it "returns true when expires_at is in the past" do
      credential = build(:integration_credential, expires_at: 1.minute.ago)

      expect(credential).to be_expired
    end

    it "returns true at the boundary when expires_at equals current time" do
      credential = build(:integration_credential, expires_at: Time.current)

      expect(credential).to be_expired
    end

    it "returns false when revoked even if expired" do
      credential = build(:integration_credential, :revoked, expires_at: 1.hour.ago)

      expect(credential).not_to be_expired
    end
  end

  describe "#revoke!" do
    it "sets revoked_at to the current time" do
      credential = create(:integration_credential)

      freeze_time do
        credential.revoke!

        expect(credential.revoked_at).to eq(Time.current)
        expect(credential).to be_revoked
        expect(credential).not_to be_active
      end
    end
  end
end
