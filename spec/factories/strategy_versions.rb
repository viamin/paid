# frozen_string_literal: true

FactoryBot.define do
  factory :strategy_version do
    strategy
    sequence(:version) { |n| n }
    content do
      {
        "decomposition_approach" => "parallel",
        "max_parallel_agents" => 2,
        "retry_policy" => { "type" => "exponential", "attempts" => 3 }
      }
    end
    provenance { { "source" => "human" } }
    promotion_state { "draft" }
    created_by { "human" }

    trait :candidate do
      promotion_state { "candidate" }
    end

    trait :active do
      promotion_state { "active" }
      promoted_at { Time.current }
      association :promoted_by_user, factory: :user
    end

    trait :retired do
      promotion_state { "retired" }
      retired_at { Time.current }
    end

    trait :rejected do
      promotion_state { "rejected" }
    end
  end
end
