# frozen_string_literal: true

FactoryBot.define do
  factory :layered_verification_finding do
    project
    obligation { association :layered_verification_obligation, project: project }
    agent_run { association :agent_run, project: project, goal: "layered_verification_audit" }
    correspondence_claim_type { "none" }
    cause_signature { SecureRandom.uuid }
    source_passages { [] }
    observed_behavior { "Observed behavior" }
    question { "What should happen?" }
    options { [] }
    consequences { [] }
  end
end
