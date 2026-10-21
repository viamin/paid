# frozen_string_literal: true

FactoryBot.define do
  factory :feature_intent_facet_assessment do
    feature_intent_facet_direction
    account { feature_intent_facet_direction.account }
    evidence_revision { 1 }
    status { "unknown" }
    rubric_version { "v1" }
    model_version { "test-model" }
  end

  factory :feature_intent_issue_prerequisite_mapping do
    feature_intent_issue
    account { feature_intent_issue.feature_intent.project.account }
    coverage_assessment { "unknown" }
    scope_revision { "scope-v1" }
    relevant_design_documents { [] }
  end

  factory :feature_intent_issue_prerequisite do
    feature_intent_issue_prerequisite_mapping
    feature_intent_facet
    account { feature_intent_issue_prerequisite_mapping.account }
    materiality_rationale { "This facet directly constrains the issue scope." }
  end
end
