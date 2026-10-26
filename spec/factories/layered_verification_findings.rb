# frozen_string_literal: true

FactoryBot.define do
  factory :layered_verification_finding do
    obligation { association :layered_verification_obligation }
    project { obligation.project }
    agent_run { association :agent_run, project:, goal: "layered_verification_audit", issue: nil,
      external_metadata: { "layered_verification_audit" => { "obligation_ids" => [ obligation.id ] } } }
    correspondence_claim_type { "business_to_spec" }
    sequence(:cause_signature) { |n| "missing-behavior-#{n}" }
    observed_behavior { "The implementation retries after a rejected cancellation." }
    check_limitations { "The observation is limited to the recorded source and revision." }
    question { "Should the documented cancellation behavior or implementation change?" }
  end
end
