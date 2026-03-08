# frozen_string_literal: true

FactoryBot.define do
  factory :ab_test_variant do
    ab_test
    prompt_version { association :prompt_version, prompt: ab_test.prompt, strategy: :create }
    is_control { false }
    sample_count { 0 }
    total_quality_score { 0 }
  end
end
