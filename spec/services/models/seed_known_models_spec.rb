# frozen_string_literal: true

require "rails_helper"

RSpec.describe Models::SeedKnownModels do
  describe ".call" do
    let(:registry) { instance_double(RubyLLM::Models, all: registry_models) }
    let(:registry_models) { [] }

    before do
      allow(RubyLLM).to receive(:models).and_return(registry)
      allow(registry).to receive(:refresh).and_return(true)
    end

    it "creates model records from known models" do
      expect { described_class.call }.to change(LlmModel, :count).by(described_class::KNOWN_MODELS.size)
    end

    # @spec MODEL-SELECTION-005
    # GPT-5.6 Luna/Terra/Sol are api_key-only under the agent-harness Codex
    # subscription contract (#3965), so the snapshot marks them `active:
    # false` to clear the catalog contract drift detector. Their tier labels
    # still back-fill from KNOWN_MODELS so the api_key auth path can rank
    # them when the runner contract catches up.
    it "marks GPT-5.6 tier variants inactive under the Codex subscription contract" do
      2.times { described_class.call }

      { "gpt-5.6-luna" => "low", "gpt-5.6-terra" => "mid", "gpt-5.6-sol" => "high" }.each do |id, tier|
        expect(LlmModel.find_by!(model_id: id)).to have_attributes(active: false, tier: tier)
      end
    end

    it "refreshes the registry before reading models" do
      described_class.call

      expect(registry).to have_received(:refresh).once
    end

    # @spec DIRECT-OUTBOUND-CATALOG-002
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
      allow(registry).to receive(:refresh).and_raise(Faraday::ConnectionFailed.new("registry down"))
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
      expect(LlmModel.find_by(model_id: "glm-5.2").provider).to eq("zai_coding")
      expect(LlmModel.find_by(model_id: "glm-5.2").tier).to eq("mid")
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

    it "retires seeded catalog rows that have dropped out of KNOWN_MODELS" do
      stale = LlmModel.create!(
        model_id: "claude-sonnet-4-7",
        display_name: "Claude Sonnet 4.7",
        provider: "anthropic",
        category: "coding",
        catalog_source: "seeded",
        active: true
      )

      described_class.call

      expect(stale.reload.active).to be(false)
    end

    it "leaves manually managed catalog rows active when they fall outside KNOWN_MODELS" do
      manual = LlmModel.create!(
        model_id: "custom-internal-model",
        display_name: "Custom",
        provider: "openai",
        category: "coding",
        catalog_source: "manual",
        active: true
      )

      described_class.call

      expect(manual.reload.active).to be(true)
    end

    it "reactivates seeded rows that are back in KNOWN_MODELS" do
      model = LlmModel.create!(
        model_id: "gpt-5.1",
        display_name: "GPT-5.1",
        provider: "openai",
        category: "coding",
        catalog_source: "seeded",
        active: false
      )

      described_class.call

      expect(model.reload.active).to be(true)
    end

    it "honors seeded inactive models from the snapshot" do
      described_class.call

      expect(LlmModel.find_by!(model_id: "gpt-5.5-pro").active).to be(false)
      expect(LlmModel.find_by!(model_id: "gpt-5.3-codex").active).to be(false)
    end

    # @spec MODEL-AVAILABILITY-002
    it "preserves an operator's explicit disable across scheduled sync" do
      model = LlmModel.create!(
        model_id: "gpt-5.1",
        display_name: "GPT-5.1",
        provider: "openai",
        category: "coding",
        catalog_source: "seeded",
        active: true
      )
      model.operator_disable!

      described_class.call

      expect(model.reload.active).to be(false)
    end

    # @spec MODEL-AVAILABILITY-002
    it "preserves an operator's explicit enable across scheduled sync, even over a snapshot exclusion" do
      model = LlmModel.create!(
        model_id: "gpt-5.3-codex",
        display_name: "GPT-5.3 Codex",
        provider: "openai",
        category: "coding",
        catalog_source: "seeded",
        active: false
      )
      model.operator_enable!

      described_class.call

      expect(model.reload.active).to be(true)
    end

    # @spec MODEL-AVAILABILITY-003
    it "does not reapply a stale snapshot exclusion over validated availability evidence" do
      model = LlmModel.create!(
        model_id: "gpt-5.3-codex",
        display_name: "GPT-5.3 Codex",
        provider: "openai",
        category: "coding",
        catalog_source: "seeded",
        active: true
      )
      ModelAvailabilityCheck.create!(
        llm_model: model,
        runner_key: "codex",
        auth_type: "subscription",
        status: "available",
        source: "agent_harness_compat",
        checked_at: Time.current
      )

      described_class.call

      expect(model.reload.active).to be(true)
    end

    # @spec MODEL-AVAILABILITY-003
    it "reapplies the snapshot exclusion when availability evidence is stale" do
      model = LlmModel.create!(
        model_id: "gpt-5.3-codex",
        display_name: "GPT-5.3 Codex",
        provider: "openai",
        category: "coding",
        catalog_source: "seeded",
        active: true
      )
      ModelAvailabilityCheck.create!(
        llm_model: model,
        runner_key: "codex",
        auth_type: "subscription",
        status: "available",
        source: "agent_harness_compat",
        checked_at: (ModelAvailabilityCheck::DEFAULT_TTL + 1.hour).ago
      )

      described_class.call

      expect(model.reload.active).to be(false)
    end

    # @spec DIRECT-OUTBOUND-CATALOG-001
    it "gives every direct-outbound provider a dropdown-eligible catalog row (RDR-065)" do
      described_class.call

      Runner::DIRECT_OUTBOUND_API_PROVIDERS.each_value do |config|
        expect(LlmModel.dropdown_options_for(config.fetch(:service_type))).not_to be_empty,
          "expected #{config.fetch(:service_type)} to have at least one active catalog row"
      end
    end

    # @spec DIRECT-OUTBOUND-CATALOG-003
    it "seeds the openrouter pareto row as a seeded (not openrouter_sync) paid catalog entry" do
      described_class.call

      pareto = LlmModel.find_by!(model_id: "openrouter/pareto-code")
      expect(pareto.provider).to eq("openrouter")
      expect(pareto.catalog_source).to eq("seeded")
      expect(pareto.pricing_tier).to eq("paid")
      expect(pareto.active).to be(true)
    end

    # @spec DIRECT-OUTBOUND-CATALOG-001
    it "seeds catalog rows for deepseek, mistral, xai, zai, and inception" do
      described_class.call

      expect(LlmModel.find_by(model_id: "deepseek-chat").provider).to eq("deepseek")
      expect(LlmModel.find_by(model_id: "devstral-2512").provider).to eq("mistral")
      expect(LlmModel.find_by(model_id: "grok-4.3").provider).to eq("xai")
      expect(LlmModel.find_by(model_id: "glm-5.2v").provider).to eq("zai")
      expect(LlmModel.find_by(model_id: "mercury-2").provider).to eq("inception")
    end
  end

  def registry_model(id:, name: id, provider:, family: "test-family", context_window: 123_456,
    max_output_tokens: 4_096, capabilities: [], pricing: {}, modalities: {})
    RubyLLM::Model.new(
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
