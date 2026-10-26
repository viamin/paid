# frozen_string_literal: true

FactoryBot.define do
  factory :layered_verification_finding do
    obligation { association :layered_verification_obligation }
    project { obligation.project }
    obligation_external_identity { obligation.external_identity }
    correspondence_claim_type { "spec_to_code" }
    sequence(:cause_signature) { |n| "unmapped-behavior-#{n}" }
    status { "open" }
    summary { "Observed behavior has no declared correspondence." }
    observations { [] }
  end
end
