# frozen_string_literal: true

FactoryBot.define do
  factory :coordination_policy do
    account
    project { nil }
    policy_type { "decomposition" }
    sequence(:policy_key) { |n| "coordination-policy-#{n}" }
    sequence(:name) { |n| "Coordination Policy #{n}" }
    status { "draft" }
    context_selector { {} }
    metadata { {} }

    trait :active do
      status { "active" }
    end

    trait :project_scoped do
      project { association :project, account: account }
    end
  end
end
