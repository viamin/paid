# frozen_string_literal: true

FactoryBot.define do
  factory :layered_verification_finding do
    project
    obligation { association :layered_verification_obligation, project: project }
    agent_run { association :agent_run, project: project, goal: "layered_verification_audit" }
    correspondence_claim_type { "business_to_spec" }
    sequence(:cause_signature) { |number| "contradicted-correspondence-#{number}" }
    observed_behavior { "Observed implementation conflicts with the declared correspondence." }
    question { "Which authoritative interpretation should govern this scope?" }
  end
end
