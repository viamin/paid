# frozen_string_literal: true

require "rails_helper"

RSpec.describe Providers::DefaultTierModelIds do
  describe ".call" do
    before do
      create(:llm_model, model_id: "haiku-1", provider: "anthropic", tier: "low", capability_score: 7.0)
      create(:llm_model, model_id: "sonnet-1", provider: "anthropic", tier: "mid", capability_score: 9.0)
      create(:llm_model, model_id: "opus-1", provider: "anthropic", tier: "high", capability_score: 10.0)
      create(:llm_model, model_id: "gpt4o-mini-1", provider: "openai", tier: "low", capability_score: 6.5)
      create(:llm_model, model_id: "gpt4o-1", provider: "openai", tier: "mid", capability_score: 8.5)
    end

    it "returns the highest-capability model per tier for claude" do
      expect(described_class.call(provider_key: "claude")).to eq(
        "low" => "haiku-1",
        "mid" => "sonnet-1",
        "high" => "opus-1"
      )
    end

    it "returns openai mappings for codex" do
      result = described_class.call(provider_key: "codex")
      expect(result["low"]).to eq("gpt4o-mini-1")
      expect(result["mid"]).to eq("gpt4o-1")
    end

    it "returns an empty hash for an unmapped provider_key" do
      expect(described_class.call(provider_key: "opencode")).to eq({})
    end
  end
end
