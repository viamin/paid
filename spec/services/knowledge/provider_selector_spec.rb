# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::ProviderSelector do
  let(:user) { create(:user) }
  let(:setting) do
    create(
      :user_setting,
      user: user,
      kb_embedding_provider: "openai",
      kb_embedding_fallback_providers: %w[openrouter deepseek],
      kb_chat_provider: "claude",
      kb_chat_fallback_providers: %w[cursor codex],
      circuit_breaker_timeout_seconds: 300
    )
  end

  describe ".for_embedding" do
    it "returns the configured provider order" do
      expect(described_class.for_embedding(user_setting: setting)).to eq(%w[openai openrouter deepseek])
    end

    it "filters out unavailable providers" do
      create(:provider_state, user: user, provider_name: "openrouter", rate_limited_until: 5.minutes.from_now)
      create(:provider_state, :circuit_open, user: user, provider_name: "deepseek")

      expect(described_class.for_embedding(user_setting: setting)).to eq([ "openai" ])
    end

    it "logs the embedding compatibility warning when fallbacks are configured" do
      allow(Rails.logger).to receive(:warn)

      described_class.for_embedding(user_setting: setting)

      expect(Rails.logger).to have_received(:warn).with(
        hash_including(
          message: "knowledge.provider_selector.embedding_fallback_requires_compatible_model",
          user_setting_id: setting.id,
          providers: %w[openai openrouter deepseek],
          model: Knowledge::Embeddings::Generate::MODEL,
          dimensions: Knowledge::Embeddings::Generate::DIMENSIONS
        )
      )
    end
  end

  describe ".for_chat" do
    it "returns the configured provider order" do
      expect(described_class.for_chat(user_setting: setting)).to eq(%w[claude cursor codex])
    end

    it "allows a circuit-open provider back in once the recovery timeout elapses" do
      state = create(
        :provider_state,
        :circuit_open,
        user: user,
        provider_name: "cursor",
        circuit_opened_at: 10.minutes.ago
      )

      expect(described_class.for_chat(user_setting: setting)).to eq(%w[claude cursor codex])
      expect(state.reload.circuit_state).to eq("half_open")
    end
  end
end
