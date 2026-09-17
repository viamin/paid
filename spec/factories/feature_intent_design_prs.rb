# frozen_string_literal: true

FactoryBot.define do
  factory :feature_intent_design_pr do
    feature_intent
    sequence(:pull_request_number) { |n| n }
    design_pr_kind { "rdr" }
    required { true }
    head_sha { "a" * 40 }
    reviewed_head_sha { "a" * 40 }

    trait :stale do
      head_sha { "b" * 40 }
      reviewed_head_sha { "a" * 40 }
    end

    trait :merged do
      merged_at { 1.hour.ago }
    end
  end
end
