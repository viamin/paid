# frozen_string_literal: true

FactoryBot.define do
  factory :layered_verification_check_result do
    obligation { association :layered_verification_obligation }
    producer { "formal_verification" }
    execution_state { "completed" }
    obligation_coverage { "supported" }
    input_revision { { "intent" => "abc123" } }
    limitations { "bounded state space" }
  end
end
