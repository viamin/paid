# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::RunnerSelector do
  let(:user) { create(:user) }
  let(:setting) do
    create(
      :user_setting,
      user: user,
      kb_embedding_runner: "openai",
      kb_embedding_fallback_runners: %w[openrouter deepseek],
      kb_chat_runner: "claude",
      kb_chat_fallback_runners: %w[cursor codex],
      circuit_breaker_timeout_seconds: 300
    )
  end

  describe ".for_embedding" do
    it "returns the configured runner order" do
      expect(described_class.for_embedding(user_setting: setting)).to eq(%w[openai openrouter deepseek])
    end

    it "filters out unavailable runners" do
      create(:runner_state, user: user, runner_name: "openrouter", rate_limited_until: 5.minutes.from_now)
      create(:runner_state, :circuit_open, user: user, runner_name: "deepseek")

      expect(described_class.for_embedding(user_setting: setting)).to eq([ "openai" ])
    end

    it "logs the embedding compatibility warning when fallbacks are configured" do
      allow(Rails.logger).to receive(:warn)

      described_class.for_embedding(user_setting: setting)

      expect(Rails.logger).to have_received(:warn).with(
        hash_including(
          message: "knowledge.runner_selector.embedding_fallback_requires_compatible_model",
          user_setting_id: setting.id,
          runners: %w[openai openrouter deepseek],
          model: Knowledge::Embeddings::Generate::DEFAULT_MODEL,
          dimensions: Knowledge::Embeddings::Generate::DEFAULT_DIMENSIONS
        )
      )
    end

    it "logs the configured model and dimensions in the embedding fallback warning" do
      setting.update!(kb_embedding_model: "text-embedding-3-small", kb_embedding_dimensions: 1536)
      allow(Rails.logger).to receive(:warn)

      described_class.for_embedding(user_setting: setting)

      expect(Rails.logger).to have_received(:warn).with(
        hash_including(
          model: "text-embedding-3-small",
          dimensions: 1536
        )
      )
    end
  end

  describe ".for_chat" do
    it "returns the configured runner order" do
      expect(described_class.for_chat(user_setting: setting)).to eq(%w[claude cursor codex])
    end

    it "skips legacy unsupported chat runners and logs a warning" do
      setting.update_columns(
        kb_chat_runner: "not-a-runner",
        kb_chat_fallback_runners: [ "claude", "also-invalid" ]
      )
      allow(Rails.logger).to receive(:warn)

      expect(described_class.for_chat(user_setting: setting)).to eq([ "claude" ])
      expect(Rails.logger).to have_received(:warn).with(
        hash_including(
          message: "knowledge.runner_selector.unsupported_runner_configured",
          user_setting_id: setting.id,
          operation: :chat,
          runners: %w[not-a-runner also-invalid]
        )
      )
    end

    it "allows a circuit-open runner back in once the recovery timeout elapses" do
      state = create(
        :runner_state,
        :circuit_open,
        user: user,
        runner_name: "cursor",
        circuit_opened_at: 10.minutes.ago
      )

      expect(described_class.for_chat(user_setting: setting)).to eq(%w[claude cursor codex])
      expect(state.reload.circuit_state).to eq("half_open")
    end
  end
end
