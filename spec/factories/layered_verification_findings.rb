# frozen_string_literal: true

FactoryBot.define do
  factory :layered_verification_finding do
    project
    obligation { association :layered_verification_obligation, project: }
    agent_run { association :agent_run, project:, goal: "layered_verification_audit" }
    correspondence_claim_type { "spec_to_code" }
    sequence(:cause_signature) { |n| "verification-conflict-#{n}" }
  end
end
