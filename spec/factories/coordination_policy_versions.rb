# frozen_string_literal: true

FactoryBot.define do
  factory :coordination_policy_version do
    coordination_policy
    sequence(:version) { |n| n }
    status { "draft" }
    rules { {} }
    parameters { {} }
    metadata { {} }

    trait :active do
      status { "active" }
      activated_at { Time.current }
    end

    trait :retired do
      status { "retired" }
      retired_at { Time.current }
    end
  end
end
