# frozen_string_literal: true

FactoryBot.define do
  factory :quality_metric do
    agent_run
    metric_type { "automated" }
    scores do
      {
        "pr_created" => 1.0,
        "ci_passed" => 1.0,
        "iterations" => 0.9,
        "lint_clean" => 1.0,
        "tests_pass" => 1.0
      }
    end
    composite_score { 0.9813 }
    feedback_source { "system" }

    trait :automated do
      metric_type { "automated" }
      feedback_source { "system" }
    end

    trait :human do
      metric_type { "human" }
      feedback_source { "pr_merge" }
      scores { { "pr_merged" => 1.0 } }
      composite_score { 1.0 }
    end

    trait :with_prompt_version do
      prompt_version
    end

    trait :low_quality do
      scores do
        {
          "pr_created" => 0.0,
          "ci_passed" => 0.0,
          "iterations" => 0.0,
          "lint_clean" => 0.0,
          "tests_pass" => 0.0
        }
      end
      composite_score { 0.0 }
    end
  end
end
