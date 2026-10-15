# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::SettingsReadiness do
  describe ".call" do
    # @spec KNOWLEDGE-SETTINGS-001
    it "reports the newest matching owner key selected by knowledge execution" do
      owner = create(:user)
      owner.settings.update!(kb_embedding_runner: "openai", kb_embedding_fallback_runners: [ "openrouter" ])
      create(:provider_api_key, user: owner, name: "Older OpenAI", api_service_type: "openai")
      selected_key = create(:provider_api_key, user: owner, name: "Knowledge OpenAI", api_service_type: "openai")

      result = described_class.call(owner: owner)
      primary = result.fetch(:embedding).first
      fallback = result.fetch(:embedding).second

      expect(primary.role).to eq("Primary")
      expect(primary.readiness).to have_attributes(
        status: "ready",
        credential_source: "owner_api_key",
        credential_service: "openai",
        credential_name: selected_key.name
      )
      expect(fallback).to have_attributes(role: "Fallback 1")
      expect(fallback.readiness.status).to eq("missing_credential")
      expect(fallback.readiness.credential_service).to eq("openrouter")
    end

    it "reports an explicitly selected key instead of a newer matching key" do
      owner = create(:user)
      selected_key = create(:provider_api_key, user: owner, name: "Selected OpenAI", api_service_type: "openai")
      create(:provider_api_key, user: owner, name: "Newer OpenAI", api_service_type: "openai")
      owner.settings.update!(kb_embedding_provider_api_key: selected_key)

      readiness = described_class.call(owner: owner).fetch(:embedding).first.readiness

      expect(readiness).to have_attributes(
        status: "ready",
        credential_source: "saved_key",
        credential_service: "openai",
        credential_name: selected_key.name
      )
    end

    it "reports an incompatible selected key as invalid" do
      owner = create(:user)
      owner.settings.update!(kb_embedding_provider_api_key: create(:provider_api_key, user: owner, api_service_type: "anthropic"))

      readiness = described_class.call(owner: owner).fetch(:embedding).first.readiness

      expect(readiness).to have_attributes(
        status: "invalid_credential",
        credential_source: "saved_key",
        credential_service: "openai",
        credential_name: nil
      )
    end
  end
end
