# frozen_string_literal: true

FactoryBot.define do
  factory :layered_verification_finding do
    project
    obligation { association :layered_verification_obligation, project: }
    agent_run { association :agent_run, project:, goal: "layered_verification_audit" }
    correspondence_claim_type { "spec_to_code" }
    cause_signature { "missing-transition" }
    source_passages { "The specification requires a retry transition." }
    observed_behavior { "The implementation returns after the first failure." }
    limitations { "Observed from the selected source and test evidence." }
  end
end
