# frozen_string_literal: true

FactoryBot.define do
  factory :ab_test do
    prompt { association :prompt, :with_version, strategy: :create }
    sequence(:name) { |n| "A/B Test #{n}" }
    status { "draft" }
    min_samples_per_variant { 30 }
    confidence_threshold { 0.95 }
    control_version { prompt.current_version }
  end
end
