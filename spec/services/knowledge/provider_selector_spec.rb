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

  # @spec ISSUE-ANALYSIS-001
  describe ".for_issue_analysis" do
    let(:issue_setting) do
      create(
        :user_setting,
        user: user,
        issue_analysis_runner: "codex",
        issue_analysis_fallback_runners: %w[cursor gemini],
        circuit_breaker_timeout_seconds: 300
      )
    end

    it "returns the configured issue analysis runner order" do
      expect(described_class.for_issue_analysis(user_setting: issue_setting)).to eq(%w[codex cursor gemini])
    end

    it "returns an empty array when no issue analysis runner is configured" do
      blank_setting = create(:user_setting, user: create(:user), issue_analysis_runner: "", issue_analysis_fallback_runners: [])

      expect(described_class.for_issue_analysis(user_setting: blank_setting)).to eq([])
    end

    it "filters out unavailable runners" do
      create(:runner_state, :rate_limited, user: user, runner_name: "codex")

      expect(described_class.for_issue_analysis(user_setting: issue_setting)).to eq(%w[cursor gemini])
    end

    it "rejects an unsupported runner configured outside the supported set" do
      issue_setting.update_columns(issue_analysis_runner: "not-a-runner")
      allow(Rails.logger).to receive(:warn)

      expect(described_class.for_issue_analysis(user_setting: issue_setting)).to eq(%w[cursor gemini])
    end
  end

  # @spec ISSUE-ANALYSIS-002 LLM-ROUTING-005
  describe ".available_standalone_text_runner_identifiers" do
    before { user.runners.delete_all }

    it "preserves an API-key Codex credential when the subscription requires isolation" do
      subscription = create(:runner, user: user, runner_key: "codex", auth_type: "subscription")
      credential = create(:runner_api_key, user: user, api_service_type: "openai")
      api_runner = create(:runner, :api_key, user: user, runner_key: "codex", provider_api_key: credential)
      provider_class = class_double(AgentHarness::Providers::Codex)
      provider = instance_double(AgentHarness::Providers::Codex, supports_tool_control?: false)
      allow(AgentHarness).to receive(:provider_class).with(:codex).and_return(provider_class)
      allow(provider_class).to receive(:new).and_return(provider)

      expect(described_class.available_standalone_text_runner_identifiers(user_setting: setting)).to eq([ api_runner.routing_key ])
      expect(api_runner.routing_key).not_to eq(subscription.routing_key)
    end

    it "excludes a credential whose own runner state is unavailable" do
      credential = create(:runner_api_key, user: user, api_service_type: "openai")
      runner = create(:runner, :api_key, user: user, runner_key: "codex", provider_api_key: credential)
      create(:runner_state, :rate_limited, user: user, runner_name: runner.state_key)

      expect(described_class.available_standalone_text_runner_identifiers(user_setting: setting)).to eq([])
    end
  end
end
