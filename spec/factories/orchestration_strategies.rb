# frozen_string_literal: true

FactoryBot.define do
  factory :orchestration_strategy do
    strategy_type { "review_settings" }
    name { "Review Settings" }
    version { 1 }
    configuration { OrchestrationStrategies::Defaults.review_settings }
    active { true }
    account { nil }

    trait :with_account do
      account
    end

    trait :inactive do
      active { false }
    end

    OrchestrationStrategy::STRATEGY_TYPES.each do |type|
      trait type.to_sym do
        strategy_type { type }
        name { type.titleize }
        configuration { OrchestrationStrategies::Defaults.configuration_for(type) }
      end
    end
  end
end
