# frozen_string_literal: true

FactoryBot.define do
  factory :layered_verification_finding do
    project
    obligation { association :layered_verification_obligation, project: project }
    originating_audit_run { association :agent_run, project: project, goal: "layered_verification_audit" }
    correspondence_claim_type { "business_to_spec" }
    sequence(:cause_signature) { |n| "missing-correspondence-#{n}" }
    observed_behavior { "The implementation does not preserve the documented ordering." }
    limitations { "The audit was limited to the selected revision." }
    decision_question { "Which ordering is authoritative?" }
  end
end
