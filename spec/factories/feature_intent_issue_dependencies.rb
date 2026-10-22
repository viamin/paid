# frozen_string_literal: true

FactoryBot.define do
  factory :feature_intent_issue_dependency do
    feature_intent_issue
    depends_on_feature_intent_issue { association :feature_intent_issue, feature_intent: feature_intent_issue.feature_intent }
  end
end
