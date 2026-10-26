# frozen_string_literal: true

FactoryBot.define do
  factory :layered_verification_finding do
    obligation { association :layered_verification_obligation }
    project { obligation.project }
    correspondence_claim_type { "business_to_model" }
    sequence(:cause_signature) { |n| "missing-transition-#{n}" }
    source_passages { "The customer can cancel before settlement." }
    observed_behavior { "Cancellation is rejected after authorization." }
    decision_question { "Should authorized payments remain cancellable?" }
  end
end
