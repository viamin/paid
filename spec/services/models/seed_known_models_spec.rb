# frozen_string_literal: true

require "rails_helper"

RSpec.describe Models::SeedKnownModels do
  describe ".call" do
    it "creates model records from known models" do
      expect { described_class.call }.to change(LlmModel, :count).by(described_class::KNOWN_MODELS.size)
    end

    it "updates existing models on re-sync" do
      described_class.call

      expect { described_class.call }.not_to change(LlmModel, :count)
    end

    it "sets correct attributes for Claude Sonnet" do
      described_class.call

      model = LlmModel.find_by(model_id: "claude-sonnet-4-6")
      expect(model).to be_present
      expect(model.provider).to eq("anthropic")
      expect(model.input_cost_per_million).to eq(3.0)
      expect(model.capability_score).to eq(9.0)
    end

    it "assigns tier to seeded models" do
      described_class.call

      expect(LlmModel.find_by(model_id: "claude-haiku-4-5-20251001").tier).to eq("low")
      expect(LlmModel.find_by(model_id: "gpt-4o-mini").tier).to eq("low")
      expect(LlmModel.find_by(model_id: "claude-sonnet-4-6").tier).to eq("mid")
      expect(LlmModel.find_by(model_id: "gpt-4o").tier).to eq("mid")
      expect(LlmModel.find_by(model_id: "gemini-2.5-pro").tier).to eq("mid")
      expect(LlmModel.find_by(model_id: "claude-opus-4-6").tier).to eq("high")
    end

    it "backfills tier on existing rows that lack it" do
      existing = LlmModel.create!(
        model_id: "claude-opus-4-6",
        display_name: "Outdated",
        provider: "anthropic",
        category: "coding",
        tier: nil
      )

      described_class.call

      expect(existing.reload.tier).to eq("high")
    end
  end
end
