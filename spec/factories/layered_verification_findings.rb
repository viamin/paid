# frozen_string_literal: true

FactoryBot.define do
  factory :layered_verification_finding do
    obligation { association(:layered_verification_obligation) }
    project { obligation.project }
    obligation_external_identity { obligation.external_identity }
    correspondence_claim_type { "business_to_spec" }
    sequence(:cause_signature) { |n| "cause-#{n}" }
    observed_behavior { "Observed behavior differs from the source." }
    check_limitations { "The check did not execute dynamic scenarios." }
    question { "Which behavior should govern?" }
  end
end
