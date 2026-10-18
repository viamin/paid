# frozen_string_literal: true

require "rails_helper"

# @spec FACET-CONFIDENCE-008
RSpec.describe FeatureIntentIssuePrerequisite do
  it "rejects a facet belonging to a different feature intent" do
    mapping = create(:feature_intent_issue_prerequisite_mapping)
    other_feature = create(:feature_intent, project: mapping.feature_intent_issue.feature_intent.project)
    other_facet = create(:feature_intent_facet, feature_intent: other_feature)
    prerequisite = build(:feature_intent_issue_prerequisite,
      feature_intent_issue_prerequisite_mapping: mapping,
      feature_intent_facet: other_facet)

    expect(prerequisite).not_to be_valid
    expect(prerequisite.errors[:feature_intent_facet]).to be_present
  end

  it "accepts a facet belonging to the mapped issue's feature intent" do
    mapping = create(:feature_intent_issue_prerequisite_mapping)
    facet = create(:feature_intent_facet, feature_intent: mapping.feature_intent_issue.feature_intent)
    prerequisite = build(:feature_intent_issue_prerequisite,
      feature_intent_issue_prerequisite_mapping: mapping,
      feature_intent_facet: facet)

    expect(prerequisite).to be_valid
  end
end
