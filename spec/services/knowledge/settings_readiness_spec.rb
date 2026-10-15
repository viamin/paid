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
  end
end
