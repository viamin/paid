# frozen_string_literal: true

FactoryBot.define do
  factory :layered_verification_correspondence_claim do
    obligation { association :layered_verification_obligation }
    claim_type { "business_to_model" }
    sequence(:source_reference) { |n| "docs/intent/payments/design.md#L#{n}" }
    sequence(:target_reference) { |n| "app/models/payment_#{n}.rb" }
    abstraction_boundaries { "Intent text maps to the public API surface only." }
    assumptions { "The checkout flow stays single-currency." }
  end
end
