# frozen_string_literal: true

require "rails_helper"

RSpec.describe QualityMetric do
  describe "validations" do
    subject { build(:quality_metric) }

    it { is_expected.to validate_inclusion_of(:human_vote).in_array([ -1, 0, 1 ]).allow_nil }
  end

  describe "associations" do
    it { is_expected.to belong_to(:agent_run) }
    it { is_expected.to belong_to(:prompt_version).optional }
  end

  describe "#calculate_composite_score!" do
    it "calculates a score between 0 and 1" do
      metric = create(:quality_metric,
        ci_passed: true,
        pr_merged: true,
        iterations_to_complete: 1,
        lint_errors: 0,
        review_comments_count: 0)

      metric.calculate_composite_score!

      expect(metric.quality_score).to be_between(0.0, 1.0)
      expect(metric.quality_score).to be > 0.5
    end

    it "gives lower scores for poor metrics" do
      metric = create(:quality_metric,
        ci_passed: false,
        pr_merged: false,
        iterations_to_complete: 10,
        lint_errors: 5,
        review_comments_count: 10)

      metric.calculate_composite_score!

      expect(metric.quality_score).to be_between(0.0, 0.3)
    end
  end
end
