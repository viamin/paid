# frozen_string_literal: true

FactoryBot.define do
  factory :ab_test_variant do
    ab_test
    prompt_version { association :prompt_version, prompt: ab_test.prompt }
    sequence(:name) { |n| "variant_#{n}" }
    weight { 50 }
    sample_count { 0 }
  end
end
