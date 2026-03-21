# frozen_string_literal: true

FactoryBot.define do
  factory :token_usage do
    agent_run
    request_type { "agent" }
    input_tokens { 1000 }
    output_tokens { 500 }
    cost_cents { 1 }
    llm_model { "claude-3-5-sonnet-20241022" }
    metadata { {} }

    trait :planning do
      request_type { "planning" }
    end

    trait :evaluation do
      request_type { "evaluation" }
    end

    trait :large do
      input_tokens { 1_000_000 }
      output_tokens { 500_000 }
      cost_cents { 10_800 }
    end
  end
end
