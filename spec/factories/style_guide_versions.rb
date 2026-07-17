# frozen_string_literal: true

FactoryBot.define do
  factory :style_guide_version do
    style_guide
    version do
      (style_guide.style_guide_versions.maximum(:version) || 0) + 1
    end
    raw_content { style_guide.raw_content }
    compressed_content { style_guide.compressed_content }
    compression_metadata { style_guide.compression_metadata || {} }
    created_by { "manual" }

    trait :with_parent do
      association :parent_version, factory: :style_guide_version, style_guide: style_guide
    end
  end
end
