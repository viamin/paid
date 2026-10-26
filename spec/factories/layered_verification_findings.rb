# frozen_string_literal: true

FactoryBot.define do
  factory :layered_verification_finding do
    project
    obligation { association :layered_verification_obligation, project: project }
    agent_run { association :agent_run, project: project, goal: "layered_verification_audit" }
    correspondence_claim_type { "business_to_spec" }
    sequence(:cause_signature) { |n| "missing-correspondence-#{n}" }
    observed_behavior { "The implementation accepts an unapproved transition." }
    limitations { "Only the selected source passages were reviewed." }
    question { "Which source should govern this transition?" }
  end
end
