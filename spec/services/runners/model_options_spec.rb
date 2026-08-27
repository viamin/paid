# frozen_string_literal: true

require "rails_helper"

RSpec.describe Runners::ModelOptions do
  describe ".call" do
    subject(:options) { described_class.call(runner_key: runner_key, api_provider: api_provider, auth_type: auth_type) }

    let(:auth_type) { "api_key" }

    context "with catalog rows for the provider" do
      let(:runner_key) { "opencode" }
      let(:api_provider) { "anthropic" }

      before do
        create(:llm_model, model_id: "claude-opus-4-5", display_name: "Claude Opus 4.5", provider: "anthropic",
          family: "claude-4", tier: "high", capability_score: 10.0)
        create(:llm_model, model_id: "claude-haiku-4-5", display_name: "Claude Haiku 4.5", provider: "anthropic",
          family: "claude-4", tier: "low", capability_score: 7.0)
        create(:llm_model, model_id: "claude-3-7-sonnet", display_name: "Claude 3.7 Sonnet", provider: "anthropic",
          family: "claude-3", tier: "mid", capability_score: 8.0)
        create(:llm_model, model_id: "claude-3-5-haiku", display_name: "Claude 3.5 Haiku", provider: "anthropic",
          family: "claude-3", tier: "low", capability_score: 6.0)
        create(:llm_model, :inactive, model_id: "claude-retired", display_name: "Claude Retired", provider: "anthropic",
          family: "claude-3", tier: "low", capability_score: 5.0)
        create(:llm_model, :openai, model_id: "gpt-other-provider", family: "gpt-5", tier: "high", capability_score: 9.9)
      end

      it "returns one :model entry per active row scoped to the provider, ordered family then capability" do # @spec RUNNER-MODEL-OPTIONS-001
        model_entries = options.select(&:model?)
        expect(model_entries.map(&:value)).to eq(
          %w[claude-3-7-sonnet claude-3-5-haiku claude-opus-4-5 claude-haiku-4-5]
        )
      end

      it "carries label, optgroup family, and the catalog record on each entry" do
        entry = options.find { |o| o.value == "claude-opus-4-5" }
        expect(entry).to have_attributes(
          label: "Claude Opus 4.5",
          kind: :model,
          family: "claude-4"
        )
        expect(entry.model).to be_a(LlmModel)
        expect(entry.model.model_id).to eq("claude-opus-4-5")
      end

      it "reuses the loaded catalog row for compatibility checks" do
        expect(Runners::ModelCompatibility).to receive(:call).with(hash_including(
          model_id: "claude-3-7-sonnet",
          llm_model: have_attributes(model_id: "claude-3-7-sonnet")
        )).and_call_original
        expect(Runners::ModelCompatibility).to receive(:call).with(hash_including(
          model_id: "claude-3-5-haiku",
          llm_model: have_attributes(model_id: "claude-3-5-haiku")
        )).and_call_original
        expect(Runners::ModelCompatibility).to receive(:call).with(hash_including(
          model_id: "claude-opus-4-5",
          llm_model: have_attributes(model_id: "claude-opus-4-5")
        )).and_call_original
        expect(Runners::ModelCompatibility).to receive(:call).with(hash_including(
          model_id: "claude-haiku-4-5",
          llm_model: have_attributes(model_id: "claude-haiku-4-5")
        )).and_call_original

        options
      end

      it "falls back to the provider for the optgroup family when family is blank" do
        create(:llm_model, model_id: "claude-manual", display_name: "Claude Manual", provider: "anthropic",
          family: nil, tier: "mid", capability_score: 1.0)
        entry = options.find { |o| o.value == "claude-manual" }
        expect(entry.family).to eq("anthropic")
      end
    end

    context "with a runner/model compatibility conflict" do
      let(:api_provider) { "openai" }

      before do
        create(:llm_model, :openai, model_id: "gpt-5.6-preview", family: "gpt-5", tier: "high", capability_score: 9.9)
        create(:llm_model, :openai, model_id: "gpt-5.2-codex", family: "gpt-5", tier: "high", capability_score: 9.0)
      end

      it "excludes models the compatibility contract rejects for the auth mode" do # @spec RUNNER-MODEL-OPTIONS-002
        result = described_class.call(runner_key: "codex", api_provider: "openai", auth_type: "subscription")
        expect(result.select(&:model?).map(&:value)).to eq(%w[gpt-5.2-codex])
      end

      it "keeps the same model under a compatible auth mode" do
        result = described_class.call(runner_key: "codex", api_provider: "openai", auth_type: "api_key")
        expect(result.select(&:model?).map(&:value)).to include("gpt-5.6-preview")
      end

      it "keeps unknown-compatibility models selectable" do
        expect(described_class.call(runner_key: "opencode", api_provider: "openai", auth_type: "api_key")
          .select(&:model?).map(&:value)).to include("gpt-5.6-preview", "gpt-5.2-codex")
      end
    end

    context "with the openrouter provider" do
      let(:runner_key) { "kilocode" }
      let(:api_provider) { "openrouter" }

      before do
        create(:llm_model, model_id: "openrouter/pareto-code", display_name: "OpenRouter Pareto (Code)",
          provider: "openrouter", family: "openrouter", tier: "mid", capability_score: 8.5)
        create(:llm_model, model_id: "deepseek/deepseek-chat-v3", display_name: "DeepSeek Chat v3 (free)",
          provider: "deepseek", family: nil, tier: "mid", capability_score: 6.0,
          pricing_tier: "free", catalog_source: "openrouter_sync")
        create(:llm_model, model_id: "qwen/qwen3-coder", display_name: "Qwen3 Coder (free)",
          provider: "qwen", family: nil, tier: "high", capability_score: 7.0,
          pricing_tier: "free", catalog_source: "openrouter_sync")
      end

      it "includes the pareto row and the synced free models" do # @spec RUNNER-MODEL-OPTIONS-003
        values = options.select(&:model?).map(&:value)
        expect(values).to include("openrouter/pareto-code", "deepseek/deepseek-chat-v3", "qwen/qwen3-coder")
      end

      it "orders family-backed rows before nil-family synced rows, then by capability" do
        expect(options.select(&:model?).map(&:value)).to eq(
          %w[openrouter/pareto-code qwen/qwen3-coder deepseek/deepseek-chat-v3]
        )
      end
    end

    context "with the free policy entry" do
      let(:api_provider) { "openrouter" }

      before do
        create(:llm_model, model_id: "openrouter/pareto-code", display_name: "OpenRouter Pareto (Code)",
          provider: "openrouter", family: "openrouter", tier: "mid", capability_score: 8.5)
      end

      it "prepends it for opencode on openrouter" do # @spec RUNNER-MODEL-OPTIONS-004
        result = described_class.call(runner_key: "opencode", api_provider: "openrouter", auth_type: "api_key")
        expect(result.first).to have_attributes(
          value: described_class::FREE_POLICY_VALUE,
          label: described_class::FREE_POLICY_LABEL,
          kind: :free_policy
        )
        expect(result.first).to be_free_policy
      end

      it "does not offer it for kilocode, pi, or omp on openrouter (phase-1 gate)" do
        %w[kilocode pi omp].each do |key|
          result = described_class.call(runner_key: key, api_provider: "openrouter", auth_type: "api_key")
          expect(result.none?(&:free_policy?)).to be true
        end
      end

      it "does not offer it for opencode on another provider" do
        result = described_class.call(runner_key: "opencode", api_provider: "anthropic", auth_type: "api_key")
        expect(result.none?(&:free_policy?)).to be true
      end
    end

    context "with the custom sentinel" do
      let(:runner_key) { "opencode" }
      let(:api_provider) { "anthropic" }

      before do
        create(:llm_model, model_id: "claude-opus-4-5", display_name: "Claude Opus 4.5", provider: "anthropic",
          family: "claude-4", tier: "high", capability_score: 10.0)
      end

      it "is always the trailing entry and uses the shared catalog sentinel value" do # @spec RUNNER-MODEL-OPTIONS-005
        expect(options.last).to have_attributes(
          value: LlmModel::CUSTOM_MODEL_OPTION,
          kind: :custom
        )
        expect(options.last).to be_custom
      end

      it "is the only entry for a provider with no active catalog rows" do
        result = described_class.call(runner_key: "opencode", api_provider: "inception", auth_type: "api_key")
        expect(result.map(&:kind)).to eq(%i[custom])
        expect(result.map(&:value)).to eq([ LlmModel::CUSTOM_MODEL_OPTION ])
      end
    end
  end
end
