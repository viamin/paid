# frozen_string_literal: true

FactoryBot.define do
  factory :ab_test_variant do
    ab_test
    prompt_version { ab_test.prompt.create_version!(template: "Variant template {{title}} #{SecureRandom.hex(4)}") }
    is_control { false }
    sample_count { 0 }
    total_quality_score { 0 }
  end
end
