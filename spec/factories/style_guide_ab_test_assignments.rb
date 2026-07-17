# frozen_string_literal: true

FactoryBot.define do
  factory :style_guide_ab_test_assignment do
    style_guide_ab_test
    style_guide_ab_test_variant do
      association :style_guide_ab_test_variant, style_guide_ab_test: style_guide_ab_test, strategy: :create
    end
    agent_run
  end
end
