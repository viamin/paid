# frozen_string_literal: true

require "rails_helper"

RSpec.describe Models::PolicyEligibleReplacement do
  describe ".call" do
    subject(:replacement) { described_class.call(rejected_model: rejected_model, excluded_model_ids: excluded_model_ids) }

    let(:excluded_model_ids) { [] }

    # @spec MODEL-AVAILABILITY-006
    it "prefers a same-tier candidate over a different-tier one" do
      rejected_model = create(:llm_model, :openai, tier: "mid", capability_score: 9.0)
      same_tier = create(:llm_model, :openai, tier: "mid", capability_score: 8.5)
      other_tier = create(:llm_model, :openai, tier: "high", capability_score: 10.0)

      result = described_class.call(rejected_model: rejected_model, excluded_model_ids: [])

      expect(result).to eq(same_tier)
      expect(result).not_to eq(other_tier)
    end

    it "prefers the highest capability_score among same-tier candidates" do
      rejected_model = create(:llm_model, :openai, tier: "mid", capability_score: 9.0)
      weaker = create(:llm_model, :openai, tier: "mid", capability_score: 7.0)
      stronger = create(:llm_model, :openai, tier: "mid", capability_score: 8.9)

      result = described_class.call(rejected_model: rejected_model, excluded_model_ids: [])

      expect(result).to eq(stronger)
      expect(result).not_to eq(weaker)
    end

    it "never returns the rejected model itself" do
      rejected_model = create(:llm_model, :openai, tier: "mid")

      result = described_class.call(rejected_model: rejected_model, excluded_model_ids: [])

      expect(result).to be_nil
    end

    it "excludes explicitly passed model ids (already recorded unavailable for this context)" do
      rejected_model = create(:llm_model, :openai, tier: "mid", capability_score: 9.0)
      also_rejected = create(:llm_model, :openai, tier: "mid", capability_score: 8.9)
      eligible = create(:llm_model, :openai, tier: "mid", capability_score: 8.0)

      result = described_class.call(rejected_model: rejected_model, excluded_model_ids: [ also_rejected.model_id ])

      expect(result).to eq(eligible)
    end

    it "does not consider candidates from a different provider" do
      rejected_model = create(:llm_model, :openai, tier: "mid")
      create(:llm_model, provider: "anthropic", tier: "mid", capability_score: 10.0)

      result = described_class.call(rejected_model: rejected_model, excluded_model_ids: [])

      expect(result).to be_nil
    end

    it "does not consider inactive candidates" do
      rejected_model = create(:llm_model, :openai, tier: "mid")
      create(:llm_model, :openai, :inactive, tier: "mid", capability_score: 10.0)

      result = described_class.call(rejected_model: rejected_model, excluded_model_ids: [])

      expect(result).to be_nil
    end

    it "returns nil (no invented model) when no eligible candidate remains" do
      rejected_model = create(:llm_model, :openai, tier: "mid")

      expect(described_class.call(rejected_model: rejected_model, excluded_model_ids: [])).to be_nil
    end
  end
end
