# frozen_string_literal: true

FactoryBot.define do
  factory :notification do
    account
    sequence(:source) { |n| "test_rule_#{n}" }
    severity { :warning }
    sequence(:title) { |n| "Test notification #{n}" }
    description { "A test notification description" }
    metadata { {} }
    nav_section { "projects" }

    trait :info do
      severity { :info }
    end

    trait :warning do
      severity { :warning }
    end

    trait :error do
      severity { :error }
    end

    trait :read do
      read_at { Time.current }
    end

    trait :dismissed do
      dismissed_at { Time.current }
    end

    trait :resolved do
      resolved_at { Time.current }
    end

    trait :with_subject do
      subject { association :project, account: account }
    end

    trait :with_action_url do
      action_url { "/projects/1" }
    end
  end
end
