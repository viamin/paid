# frozen_string_literal: true

FactoryBot.define do
  factory :layered_verification_obligation do
    project
    framework { "lid" }
    sequence(:external_identity) { |n| "PAYMENTS-#{n}" }
    external_revision { "abc123" }
    scope_description { "Process a checkout payment." }
    approval_state { "approved" }

    trait :offered_cir do
      framework { "paid_offered_cir" }
      approval_state { "proposed" }
      sequence(:external_identity) { |n| ".okf/cir/checkout-#{n}.md" }
    end
  end
end
