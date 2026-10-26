# frozen_string_literal: true

FactoryBot.define do
  factory :layered_verification_finding do
    project
    obligation { association :layered_verification_obligation, project: project }
    originating_audit_run { association :agent_run, project: project, issue: nil, goal: "layered_verification_audit" }
    correspondence_claim_type { "spec_to_code" }
    sequence(:cause_signature) { |n| "unmapped-obligation-#{n}" }
    status { "open" }
    detail { {} }
  end
end
