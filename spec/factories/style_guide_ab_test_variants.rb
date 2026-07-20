# frozen_string_literal: true

FactoryBot.define do
  factory :style_guide_ab_test_variant do
    style_guide_ab_test
    style_guide_version do
      create(
        :style_guide_version,
        style_guide: style_guide_ab_test.style_guide,
        version: (style_guide_ab_test.style_guide.style_guide_versions.maximum(:version) || 0) + 1,
        raw_content: "Variant content #{SecureRandom.hex(4)}"
      )
    end
    is_control { false }
    sample_count { 0 }
    total_quality_score { 0.0 }
  end
end
