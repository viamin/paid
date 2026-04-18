# frozen_string_literal: true

FactoryBot.define do
  factory :onboarding_step do
    account
    step { "account_profile" }
    position { 0 }
    status { "pending" }

    trait :in_progress do
      status { "in_progress" }
    end

    trait :completed do
      status { "completed" }
      completed_at { Time.current }
    end

    trait :skipped do
      status { "skipped" }
      completed_at { Time.current }
    end
  end
end
