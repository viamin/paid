# frozen_string_literal: true

FactoryBot.define do
  factory :ab_test_assignment do
    ab_test
    ab_test_variant { association :ab_test_variant, ab_test: ab_test, strategy: :create }
    agent_run { association :agent_run, strategy: :create }
  end
end
