# frozen_string_literal: true

require "rails_helper"

# @spec FREE-MODEL-SYNC-003
RSpec.describe FreeModels::Classify do
  describe ".call" do
    it "scores and tiers a top-end free model as high" do
      result = described_class.call(
        context_window: 1_048_576,
        max_output_tokens: 131_072,
        supports_tools: true,
        supports_reasoning: true,
        multimodal: true
      )

      expect(result.score).to eq(10.0)
      expect(result.tier).to eq("high")
    end

    it "scores and tiers a baseline model as low" do
      result = described_class.call(
        context_window: 64_000,
        max_output_tokens: 8_000,
        supports_tools: false,
        supports_reasoning: false,
        multimodal: false
      )

      expect(result.score).to eq(3.0)
      expect(result.tier).to eq("low")
    end

    it "maps a midrange capability score to the mid tier" do
      result = described_class.call(
        context_window: 256_000,
        max_output_tokens: 40_000,
        supports_tools: true,
        supports_reasoning: false,
        multimodal: false
      )

      expect(result.score).to eq(7.5)
      expect(result.tier).to eq("mid")
    end
  end
end
