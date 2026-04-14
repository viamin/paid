# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProvidersHelper do
  describe "#provider_auth_instruction_blocks" do
    it "returns explicit copy for supported providers that define it" do
      allow(ProviderSupport).to receive(:supported_provider_keys).and_return(%w[claude codex])

      blocks = helper.provider_auth_instruction_blocks

      expect(blocks).to contain_exactly(
        hash_including(
          provider_key: "claude",
          title: Provider.display_name("claude"),
          fallback: false,
          summary: "Use one of these:"
        ),
        hash_including(
          provider_key: "codex",
          title: Provider.display_name("codex"),
          fallback: false,
          summary: "Use one of these:"
        )
      )
    end

    it "returns the generic checklist without logging for providers missing explicit copy" do
      allow(ProviderSupport).to receive(:supported_provider_keys).and_return(%w[mystery_provider])
      allow(Rails.logger).to receive(:warn)

      blocks = helper.provider_auth_instruction_blocks

      expect(blocks).to contain_exactly(
        hash_including(
          provider_key: "mystery_provider",
          title: Provider.display_name("mystery_provider"),
          fallback: true,
          summary: "Use the auth mode configured on the provider entry:"
        )
      )
      expect(Rails.logger).not_to have_received(:warn)
    end
  end
end
