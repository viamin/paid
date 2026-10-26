# frozen_string_literal: true

FactoryBot.define do
  factory :layered_verification_finding do
    project
    obligation { association :layered_verification_obligation, project: }
    agent_run { association :agent_run, project: }
    obligation_external_identity { obligation.external_identity }
    correspondence_claim_type { "spec_to_code" }
    sequence(:cause_signature) { |n| "cause-#{n}" }
    observed_behavior { "Observed behavior differs from the selected specification." }
    question { "Which behavior should govern this scope?" }
  end
end
