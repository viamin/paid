# frozen_string_literal: true

require "rails_helper"

RSpec.describe Runners::DefaultTierModelIds do
  describe ".call" do
    before do
      create(:llm_model, model_id: "haiku-1", provider: "anthropic", tier: "low", capability_score: 7.0)
      create(:llm_model, model_id: "sonnet-1", provider: "anthropic", tier: "mid", capability_score: 9.0)
      create(:llm_model, model_id: "opus-1", provider: "anthropic", tier: "high", capability_score: 10.0)
      create(:llm_model, model_id: "gpt4o-mini-1", provider: "openai", tier: "low", capability_score: 6.5)
      create(:llm_model, model_id: "gpt4o-1", provider: "openai", tier: "mid", capability_score: 8.5)
    end

    it "returns the highest-capability model per tier for claude" do
      expect(described_class.call(runner_key: "claude")).to eq(
        "low" => "haiku-1",
        "mid" => "sonnet-1",
        "high" => "opus-1"
      )
    end

    it "returns openai mappings for codex" do
      result = described_class.call(runner_key: "codex")
      expect(result["low"]).to eq("gpt4o-mini-1")
      expect(result["mid"]).to eq("gpt4o-1")
    end

    it "returns an empty hash for an unmapped provider_key" do
      expect(described_class.call(runner_key: "opencode")).to eq({})
    end

    it "returns free-model mappings for openrouter_free" do
      create(:llm_model, model_id: "free-low", provider: "openrouter", tier: "low", pricing_tier: "free", capability_score: 4.0)
      create(:llm_model, model_id: "free-mid", provider: "openrouter", tier: "mid", pricing_tier: "free", capability_score: 6.0)
      create(:llm_model, model_id: "free-high", provider: "openrouter", tier: "high", pricing_tier: "free", capability_score: 8.0)

      expect(described_class.call(runner_key: "openrouter_free")).to eq(
        "low" => "free-low",
        "mid" => "free-mid",
        "high" => "free-high"
      )
    end

    context "when the highest-capability model is supported by the updated Codex CLI" do
      before do
        create(:llm_model, model_id: "gpt-5.5", provider: "openai", tier: "high", capability_score: 9.9)
        create(:llm_model, model_id: "gpt-5.4", provider: "openai", tier: "high", capability_score: 9.6)
      end

      it "prefers the highest-capability compatible model" do
        result = described_class.call(runner_key: "codex")
        expect(result["high"]).to eq("gpt-5.5")
      end
    end

    context "when the highest-capability model has wrong provider for the runner" do
      before do
        # A google model with an inflated score won't appear in codex defaults.
        create(:llm_model, model_id: "gemini-fast", provider: "google", tier: "low", capability_score: 10.0)
      end

      it "is not included because provider doesn't match the runner" do
        result = described_class.call(runner_key: "codex")
        expect(result["low"]).not_to eq("gemini-fast")
      end
    end
  end
end
