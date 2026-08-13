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

      after(:build) do |policy|
        policy.current_version ||= build(:coordination_policy_version, :active, coordination_policy: policy)
      end

      after(:create) do |policy|
        policy.current_version.save! unless policy.current_version.persisted?
        policy.update!(current_version: policy.current_version) unless policy.current_version_id == policy.current_version.id
      end
    end

    trait :project_scoped do
      project { association :project, account: account }
    end
  end
end
