# frozen_string_literal: true

require "rails_helper"

# @spec FACET-CONFIDENCE-008
RSpec.describe FeatureIntentIssuePrerequisiteMapping do
  it "does not allow a completed coverage assessment with no material prerequisite" do
    mapping = build(:feature_intent_issue_prerequisite_mapping, coverage_assessment: "complete")

    expect(mapping).not_to be_valid
    expect(mapping.errors[:prerequisites]).to be_present
  end

  it "hands an empty completed mapping to shadow readiness as not ready" do
    mapping = create(:feature_intent_issue_prerequisite_mapping)
    mapping.update_column(:coverage_assessment, "complete")

    expect(mapping.readiness_result).not_to be_ready
    expect(mapping.readiness_result.blockers.map(&:code)).to include("prerequisite_mapping_empty")
  end
end
