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
  end
end
