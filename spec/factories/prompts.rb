# frozen_string_literal: true

FactoryBot.define do
  factory :prompt do
    sequence(:slug) { |n| "coding.prompt-#{n}" }
    sequence(:name) { |n| "Prompt #{n}" }
    category { "coding" }
    active { true }

    trait :global do
      account { nil }
      project { nil }
    end

    trait :for_account do
      account
      project { nil }
    end

    trait :for_project do
      project
      account { nil }
    end

    trait :planning do
      category { "planning" }
      sequence(:slug) { |n| "planning.prompt-#{n}" }
    end

    trait :review do
      category { "review" }
      sequence(:slug) { |n| "review.prompt-#{n}" }
    end

    trait :testing do
      category { "testing" }
      sequence(:slug) { |n| "testing.prompt-#{n}" }
    end

    trait :inactive do
      active { false }
    end

    trait :with_version do
      after(:create) do |prompt|
        prompt.create_version!(template: "Default template for {{title}}")
      end
    end
  end
end
