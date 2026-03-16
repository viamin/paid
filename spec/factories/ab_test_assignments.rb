# frozen_string_literal: true

FactoryBot.define do
  factory :ab_test_assignment do
    ab_test
    ab_test_variant
    agent_run
  end
end
