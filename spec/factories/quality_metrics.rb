# frozen_string_literal: true

FactoryBot.define do
  factory :quality_metric do
    agent_run
    quality_score { 0.75 }
    ci_passed { true }
    pr_merged { false }
    iterations_to_complete { 3 }
    lint_errors { 0 }
    test_failures { 0 }
    review_comments_count { 0 }

    trait :high_quality do
      quality_score { 0.95 }
      ci_passed { true }
      pr_merged { true }
      iterations_to_complete { 1 }
    end

    trait :low_quality do
      quality_score { 0.25 }
      ci_passed { false }
      pr_merged { false }
      iterations_to_complete { 8 }
      lint_errors { 5 }
      test_failures { 3 }
    end
  end
end
