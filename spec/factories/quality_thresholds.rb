# frozen_string_literal: true

FactoryBot.define do
  factory :quality_threshold do
    account
    project { nil }
    metric_type { "composite_score" }
    goal_type { "create_pr" }
    min_value { 0.5 }
    enabled { true }

    trait :project_override do
      project
      account { project.account }
    end

    trait :disabled do
      enabled { false }
    end
  end
end
