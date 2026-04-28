# frozen_string_literal: true

FactoryBot.define do
  factory :knowledge_recommendation do
    project
    recommendation_type { "knowledge_gap" }
    priority { "medium" }
    status { "pending" }
    description { "Missing documentation for authentication flow" }
    evidence { { source: "gap_analysis", confidence: 0.85 } }
  end
end
