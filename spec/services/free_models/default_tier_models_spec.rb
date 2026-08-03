# frozen_string_literal: true

require "rails_helper"

# @spec FREE-MODEL-RUNNER-001
RSpec.describe FreeModels::DefaultTierModels do
  describe ".call" do
    it "returns the highest-capability active above-bar free model for each tier" do
      create_free_model_candidates

      expect(described_class.call).to eq(
        "high" => "high-best",
        "mid" => "mid-best",
        "low" => "low-best"
      )
    end

    def create_free_model_candidates
      create_free_model("high-best", provider: "qwen", tier: "high", capability_score: 9.8)
      create_free_model("high-low-quality", provider: "qwen", tier: "high", capability_score: 10.0, metadata: { "below_quality_bar" => true })
      create_free_model("mid-inactive", provider: "moonshotai", tier: "mid", capability_score: 9.0, active: false)
      create_free_model("mid-best", provider: "moonshotai", tier: "mid", capability_score: 7.4)
      create_free_model("low-best", provider: "deepseek", tier: "low", capability_score: 5.1)
      create(:llm_model, model_id: "paid-high", provider: "openrouter", tier: "high", capability_score: 10.0, pricing_tier: "paid", catalog_source: "seeded")
    end

    def create_free_model(model_id, provider:, tier:, capability_score:, **attrs)
      create(:llm_model, :free,
        {
          model_id:,
          provider:,
          tier:,
          capability_score:,
          catalog_source: "openrouter_sync"
        }.merge(attrs))
    end
  end
end
