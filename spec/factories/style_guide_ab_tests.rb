# frozen_string_literal: true

FactoryBot.define do
  factory :style_guide_ab_test do
    account
    style_guide { create(:style_guide, account: account, project: nil) }
    control_version { style_guide.current_version || style_guide.style_guide_versions.order(version: :desc).first }
    sequence(:name) { |n| "Style guide A/B test #{n}" }
    status { "draft" }
    min_samples_per_variant { 30 }
    confidence_threshold { 0.95 }
  end
end
