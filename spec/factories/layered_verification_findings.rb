# frozen_string_literal: true

FactoryBot.define do
  factory :layered_verification_finding do
    obligation { association :layered_verification_obligation }
    project { obligation.project }
    correspondence_claim_type { "business_to_spec" }
    sequence(:cause_signature) { |n| "cause-#{n}" }
    status { "open" }
    detail { {} }
  end
end
