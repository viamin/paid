# frozen_string_literal: true

require "rails_helper"

RSpec.describe Models::SeedKnownModels do
  describe ".call" do
    let(:registry) { instance_double(RubyLLM::Models, all: registry_models) }
    let(:registry_models) { [] }

    before do
      allow(RubyLLM).to receive(:models).and_return(registry)
      allow(registry).to receive(:refresh!).and_return(true)
    end

    it "creates model records from known models" do
      expect { described_class.call }.to change(LlmModel, :count).by(described_class::KNOWN_MODELS.size)
    end

    it "refreshes the registry before reading models" do
      described_class.call

      expect(registry).to have_received(:refresh!).once
    end

    it "updates existing models on re-sync" do
      described_class.call

      expect { described_class.call }.not_to change(LlmModel, :count)
    end

    it "uses registry metadata when a known model is present" do
      registry_models.replace([ gpt_registry_model ])

      described_class.call

      model = LlmModel.find_by!(model_id: "gpt-5.1")
      expect(model.display_name).to eq("GPT-5.1 (Registry)")
      expect(model.family).to eq("gpt-5")
      expect(model.context_window).to eq(256_000)
      expect(model.max_output_tokens).to eq(32_768)
      expect(model.input_cost_per_million).to eq(9.99)
      expect(model.output_cost_per_million).to eq(19.99)
      expect(model.supports_tools).to be(true)
      expect(model.supports_json_output).to be(true)
      expect(model.supports_vision).to be(false)
    end

    it "preserves snapshot values when registry metadata is missing" do
      registry_models.replace([
        registry_model(
          id: "gpt-5.1",
          name: "GPT-5.1 (Registry)",
          provider: "openai",
          family: "gpt-5",
          pricing: {}
        )
      ])

      described_class.call

      model = LlmModel.find_by!(model_id: "gpt-5.1")
      expect(model.display_name).to eq("GPT-5.1 (Registry)")
      expect(model.family).to eq("gpt-5")
      expect(model.input_cost_per_million).to eq(1.25)
      expect(model.output_cost_per_million).to eq(10.0)
    end

    it "falls back to the snapshot when the registry misses a known model" do
      registry_models.replace([
        registry_model(id: "other-model", provider: "openai")
      ])

      described_class.call

      model = LlmModel.find_by!(model_id: "claude-sonnet-4-6")
      expect(model.display_name).to eq("Claude Sonnet 4.6")
      expect(model.input_cost_per_million).to eq(3.0)
      expect(model.supports_vision).to be(true)
    end

    it "falls back cleanly with a single structured warning when the registry is unavailable" do
      allow(registry).to receive(:refresh!).and_raise(Faraday::ConnectionFailed.new("registry down"))
      allow(Rails.logger).to receive(:warn)

      described_class.call

      expect(Rails.logger).to have_received(:warn).once.with(
        hash_including(
          message: "model_registry.registry_fallback",
          registry: "ruby_llm",
          reason: "registry_unavailable",
          fallback: "known_models",
          error_class: "Faraday::ConnectionFailed",
          error_message: "registry down"
        )
      )
    end

    it "assigns tier to seeded models" do
      described_class.call

      expect(LlmModel.find_by(model_id: "claude-haiku-4-5-20251001").tier).to eq("low")
      expect(LlmModel.find_by(model_id: "gpt-5-mini").tier).to eq("low")
      expect(LlmModel.find_by(model_id: "claude-sonnet-4-6").tier).to eq("mid")
      expect(LlmModel.find_by(model_id: "gpt-5.1").tier).to eq("mid")
      expect(LlmModel.find_by(model_id: "gemini-2.5-pro").tier).to eq("mid")
      expect(LlmModel.find_by(model_id: "claude-opus-4-7").tier).to eq("high")
    end

    it "backfills tier on existing rows that lack it" do
      existing = LlmModel.create!(
        model_id: "claude-opus-4-7",
        display_name: "Outdated",
        provider: "anthropic",
        category: "coding",
        tier: nil
      )

      described_class.call

      expect(existing.reload.tier).to eq("high")
    end

    it "does not overwrite an existing non-nil tier" do
      existing = LlmModel.create!(
        model_id: "claude-opus-4-7",
        display_name: "Outdated",
        provider: "anthropic",
        category: "coding",
        tier: "mid"
      )

      described_class.call

      expect(existing.reload.tier).to eq("mid")
    end
  end

  def registry_model(id:, name: id, provider:, family: "test-family", context_window: 123_456,
    max_output_tokens: 4_096, capabilities: [], pricing: {}, modalities: {})
    RubyLLM::Model::Info.new(
      id: id,
      name: name,
      provider: provider,
      family: family,
      context_window: context_window,
      max_output_tokens: max_output_tokens,
      capabilities: capabilities,
      pricing: pricing,
      modalities: modalities,
      metadata: {}
    )
  end

  def gpt_registry_model
    registry_model(
      id: "gpt-5.1",
      name: "GPT-5.1 (Registry)",
      provider: "openai",
      family: "gpt-5",
      context_window: 256_000,
      max_output_tokens: 32_768,
      capabilities: %w[function_calling structured_output],
      pricing: {
        text_tokens: {
          standard: {
            input_per_million: 9.99,
            output_per_million: 19.99
          }
        }
      }
    )
  end
end
