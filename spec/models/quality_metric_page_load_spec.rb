# frozen_string_literal: true

require "rails_helper"

RSpec.describe QualityMetric do
  describe "performance_regression focus weights" do
    # @spec FOCUSED-RUN-004
    it "weights a performance_regression run mostly on whether the finding resolved" do
      weights = described_class.weights_for(goal: "create_pr", focus: "performance_regression")

      expect(weights).to include("focus_resolved")
      expect(weights["focus_resolved"]).to be > weights.except("focus_resolved").values.max
    end

    # @spec FOCUSED-RUN-004
    it "does not fall back to the general composite weights" do
      expect(described_class.weights_for(goal: "create_pr", focus: "performance_regression"))
        .not_to eq(described_class::SCORE_WEIGHTS)
    end
  end
end
