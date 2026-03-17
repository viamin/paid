# frozen_string_literal: true

FactoryBot.define do
  factory :ab_test_variant do
    ab_test
    prompt_version do
      next_version = (ab_test.prompt.prompt_versions.maximum(:version) || 0) + 1
      create(:prompt_version, prompt: ab_test.prompt, version: next_version,
             template: "Variant template {{title}} #{SecureRandom.hex(4)}")
    end
    is_control { false }
    sample_count { 0 }
    total_quality_score { 0 }
  end
end
