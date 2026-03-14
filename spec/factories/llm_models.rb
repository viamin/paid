# frozen_string_literal: true

FactoryBot.define do
  factory :llm_model do
    sequence(:model_id) { |n| "test-model-#{n}" }
    sequence(:display_name) { |n| "Test Model #{n}" }
    provider { "anthropic" }
    category { "coding" }
    context_window { 200_000 }
    max_output_tokens { 64_000 }
    input_cost_per_million { 3.0 }
    output_cost_per_million { 15.0 }
    capability_score { 8.0 }
    active { true }

    trait :inactive do
      active { false }
    end

    trait :cheap do
      input_cost_per_million { 0.15 }
      output_cost_per_million { 0.60 }
      capability_score { 5.0 }
    end

    trait :expensive do
      input_cost_per_million { 15.0 }
      output_cost_per_million { 75.0 }
      capability_score { 10.0 }
    end

    trait :openai do
      provider { "openai" }
      sequence(:model_id) { |n| "gpt-test-#{n}" }
    end

    trait :planning do
      category { "planning" }
    end
  end
end
