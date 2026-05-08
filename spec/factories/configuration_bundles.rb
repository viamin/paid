# frozen_string_literal: true

FactoryBot.define do
  factory :configuration_bundle do
    account
    sequence(:name) { |n| "Configuration Bundle #{n}" }
    version { 1 }
    status { "draft" }
    strategy { "single_agent" }
    strategy_params { {} }
    context { {} }
  end
end
