# frozen_string_literal: true

require "rails_helper"

RSpec.describe LlmModel do
  describe "validations" do
    subject { build(:llm_model) }

    it { is_expected.to validate_presence_of(:model_id) }
    it { is_expected.to validate_uniqueness_of(:model_id) }
    it { is_expected.to validate_presence_of(:display_name) }
    it { is_expected.to validate_presence_of(:provider) }
    it { is_expected.to validate_presence_of(:category) }
    it { is_expected.to validate_inclusion_of(:category).in_array(described_class::CATEGORIES) }
  end

  describe "associations" do
    it { is_expected.to have_many(:model_selections) }
  end

  describe "scopes" do
    describe ".active" do
      it "returns only active models" do
        active = create(:llm_model, active: true)
        create(:llm_model, :inactive)

        expect(described_class.active).to eq([ active ])
      end
    end

    describe ".by_provider" do
      it "filters by provider" do
        anthropic = create(:llm_model, provider: "anthropic")
        create(:llm_model, :openai)

        expect(described_class.by_provider("anthropic")).to eq([ anthropic ])
      end
    end

    describe ".by_category" do
      it "filters by category" do
        coding = create(:llm_model, category: "coding")
        create(:llm_model, :planning)

        expect(described_class.by_category("coding")).to eq([ coding ])
      end
    end
  end

  describe "#estimated_cost" do
    it "calculates cost in cents from token counts" do
      model = build(:llm_model, input_cost_per_million: 3.0, output_cost_per_million: 15.0)

      cost = model.estimated_cost(1_000_000, 100_000)

      # Input: 3.0 * 1 = 3.0, Output: 15.0 * 0.1 = 1.5, Total: 4.5 => 450 cents
      expect(cost).to eq(450)
    end
  end

  describe ".default_for_task" do
    it "returns highest capability model for the given category" do
      create(:llm_model, category: "coding", capability_score: 7.0)
      best = create(:llm_model, category: "coding", capability_score: 9.0)

      expect(described_class.default_for_task("coding")).to eq(best)
    end

    it "falls back to any active model when category has none" do
      model = create(:llm_model, category: "coding", capability_score: 8.0)

      expect(described_class.default_for_task("review")).to eq(model)
    end
  end
end
