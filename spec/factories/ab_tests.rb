# frozen_string_literal: true

FactoryBot.define do
  factory :ab_test do
    prompt { association :prompt, :for_account, account: account }
    account
    sequence(:name) { |n| "A/B Test #{n}" }
    status { "draft" }
    traffic_percentage { 100 }
    min_sample_size { 30 }

    trait :running do
      status { "running" }
      started_at { Time.current }
    end

    trait :completed do
      status { "completed" }
      started_at { 7.days.ago }
      completed_at { Time.current }
    end

    trait :with_variants do
      after(:create) do |test|
        prompt = test.prompt
        v1 = prompt.create_version!(template: "Control template for {{title}}")
        v2 = prompt.create_version!(template: "Variant template for {{title}}")

        create(:ab_test_variant, ab_test: test, prompt_version: v1, name: "control", weight: 50)
        create(:ab_test_variant, ab_test: test, prompt_version: v2, name: "variant_a", weight: 50)
      end
    end
  end
end
