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

    # A project-scoped quality-gate threshold: applies regardless of goal.
    trait :gate do
      project
      account { project.account }
      goal_type { QualityThreshold::ALL_GOALS }
    end

    trait :critical do
      severity { "critical" }
      min_value { 0.3 }
    end

    trait :with_max do
      max_value { 0.95 }
    end
  end
end
