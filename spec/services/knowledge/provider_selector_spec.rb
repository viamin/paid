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

    it "skips legacy unsupported chat providers and logs a warning" do
      setting.update_columns(
        kb_chat_provider: "not-a-provider",
        kb_chat_fallback_providers: [ "claude", "also-invalid" ]
      )
      allow(Rails.logger).to receive(:warn)

      expect(described_class.for_chat(user_setting: setting)).to eq([ "claude" ])
      expect(Rails.logger).to have_received(:warn).with(
        hash_including(
          message: "knowledge.provider_selector.unsupported_provider_configured",
          user_setting_id: setting.id,
          operation: :chat,
          providers: %w[not-a-provider also-invalid]
        )
      )
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

  # @spec ISSUE-ANALYSIS-002
  describe ".available_chat_runner_keys" do
    before { user.runners.delete_all }

    it "returns the owner's available chat runners, excluding unavailable ones" do
      create(:runner, user: user, runner_key: "claude", enabled_for_chat: true)
      create(:runner, user: user, runner_key: "codex", enabled_for_chat: true)
      create(:runner_state, :rate_limited, user: user, runner_name: "claude")

      expect(described_class.available_chat_runner_keys(user_setting: setting)).to eq([ "codex" ])
    end

    it "returns an empty array when every chat runner is unavailable" do
      create(:runner, user: user, runner_key: "claude", enabled_for_chat: true)
      create(:runner_state, :rate_limited, user: user, runner_name: "claude")

      expect(described_class.available_chat_runner_keys(user_setting: setting)).to eq([])
    end

    it "ignores runners that are not enabled for chat" do
      create(:runner, user: user, runner_key: "claude", enabled_for_chat: true)
      create(:runner, user: user, runner_key: "codex", enabled_for_chat: false)

      expect(described_class.available_chat_runner_keys(user_setting: setting)).to eq([ "claude" ])
    end

    it "dedupes runners that share a key so each provider is tried once" do
      # An owner can legitimately hold several api_key Runner rows for the
      # same direct-outbound key (e.g. two kilocode accounts).
      key_a = create(:provider_api_key, user: user, api_service_type: "zai_coding")
      key_b = create(:provider_api_key, user: user, api_service_type: "zai_coding")
      config = { "kilocode" => { "api_provider" => "zai_coding", "model" => "glm-5.1" } }
      create(:runner, :api_key, user: user, runner_key: "kilocode", provider_api_key: key_a, name: "A", config: config)
      create(:runner, :api_key, user: user, runner_key: "kilocode", provider_api_key: key_b, name: "B", config: config)

      expect(described_class.available_chat_runner_keys(user_setting: setting)).to eq([ "kilocode" ])
    end
  end
end
