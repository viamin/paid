# frozen_string_literal: true

require "rails_helper"

RSpec.describe FreeModels::Sync do
  describe ".call" do
    let!(:paid_variant) do
      create(:llm_model,
        model_id: "deepseek/deepseek-v4-flash",
        provider: "deepseek",
        pricing_tier: "paid",
        catalog_source: "seeded")
    end

    let!(:disappeared) do
      create(:llm_model,
        model_id: "moonshotai/expired-free:free",
        display_name: "Expired Free",
        provider: "moonshotai",
        pricing_tier: "free",
        catalog_source: "openrouter_sync",
        tier: "mid",
        active: true)
    end

    let(:free_payloads) do
      [
        {
          "id" => "deepseek/deepseek-v4-flash:free",
          "name" => "DeepSeek V4 Flash Free",
          "context_length" => 1_048_576,
          "supported_parameters" => [ "tools", "reasoning" ],
          "architecture" => { "input_modalities" => [ "text", "image" ] },
          "top_provider" => { "max_completion_tokens" => 131_072 },
          "pricing" => { "prompt" => "0", "completion" => "0" },
          "expiration_date" => "2026-12-01T00:00:00Z"
        },
        {
          "id" => "qwen/qwen-lite-free",
          "name" => "Qwen Lite Free",
          "context_length" => 64_000,
          "supported_parameters" => [],
          "architecture" => { "input_modalities" => [ "text" ] },
          "top_provider" => { "max_completion_tokens" => 16_384 },
          "pricing" => { "prompt" => "0", "completion" => "0" }
        },
        {
          "id" => "anthropic/not-free",
          "name" => "Not Free",
          "context_length" => 200_000,
          "supported_parameters" => [ "tools" ],
          "architecture" => { "input_modalities" => [ "text" ] },
          "top_provider" => { "max_completion_tokens" => 32_000 },
          "pricing" => { "prompt" => "1", "completion" => "0" }
        }
      ]
    end

    before do
      allow(FreeModels::Client).to receive(:call).and_return(free_payloads)
    end

    # @spec FREE-MODEL-SYNC-001
    # @spec FREE-MODEL-SYNC-002
    # @spec FREE-MODEL-SYNC-003
    # @spec FREE-MODEL-SYNC-004
    # @spec FREE-MODEL-SYNC-005
    # @spec FREE-MODEL-SYNC-006
    # @spec FREE-MODEL-SYNC-007
    it "syncs the free catalog into openrouter_sync llm models" do
      expect {
        described_class.call
      }.to change(LlmModel.where(catalog_source: "openrouter_sync"), :count).by(2)

      synced = LlmModel.find_by!(model_id: "deepseek/deepseek-v4-flash:free")
      low_quality = LlmModel.find_by!(model_id: "qwen/qwen-lite-free")

      expect_synced_model(synced)
      expect_low_quality_model(low_quality)
      expect(disappeared.reload.active).to be(false)
      expect(LlmModel.find_by(model_id: "anthropic/not-free")).to be_nil
    end

    it "is idempotent across repeated runs" do
      described_class.call

      expect {
        described_class.call
      }.not_to change(LlmModel, :count)
    end

    # @spec DIRECT-OUTBOUND-CATALOG-004
    it "leaves the seeded openrouter/pareto-code row untouched (RDR-065)" do
      pareto = create(:llm_model,
        model_id: "openrouter/pareto-code",
        provider: "openrouter",
        pricing_tier: "paid",
        catalog_source: "seeded",
        active: true)

      described_class.call

      pareto.reload
      expect(pareto.active).to be(true)
      expect(pareto.provider).to eq("openrouter")
      expect(pareto.catalog_source).to eq("seeded")
      expect(pareto.pricing_tier).to eq("paid")
    end

    def expect_synced_model(model)
      aggregate_failures do
        expect(model.attributes.slice("pricing_tier", "catalog_source", "provider", "display_name", "data_training_risk"))
          .to eq(
            "pricing_tier" => "free",
            "catalog_source" => "openrouter_sync",
            "provider" => "deepseek",
            "display_name" => "DeepSeek V4 Flash Free",
            "data_training_risk" => "possible"
          )
        expect(model.context_window).to eq(1_048_576)
        expect(model.max_output_tokens).to eq(131_072)
        expect(model.supports_tools).to be(true)
        expect(model.supports_vision).to be(true)
        expect(model.capability_score).to eq(10.0)
        expect(model.tier).to eq("high")
        expect(model.free_variant_of).to eq(paid_variant)
        expect(model.expires_at).to eq(Time.zone.parse("2026-12-01T00:00:00Z"))
        expect(model.metadata).to include("id" => "deepseek/deepseek-v4-flash:free")
        expect(model.metadata["below_quality_bar"]).to be(false)
      end
    end

    def expect_low_quality_model(model)
      aggregate_failures do
        expect(model.provider).to eq("qwen")
        expect(model.tier).to eq("low")
        expect(model.metadata["below_quality_bar"]).to be(true)
      end
    end
  end
end
