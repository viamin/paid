# frozen_string_literal: true

FactoryBot.define do
  factory :layered_verification_finding do
    obligation { association :layered_verification_obligation }
    project { obligation.project }
    correspondence_claim_type { "direct" }
    cause_signature { "missing-retry-boundary" }
    state { "unresolved" }
    source_passages { [ { "reference" => "docs/intent/example.md:12", "text" => "Retries stop after three attempts." } ] }
    observed_behavior { "The implementation retries indefinitely." }
    check_limitations { "Observed from the bounded audit revision only." }
    decision_question { "Should the implementation adopt the documented retry bound?" }
    options { [ { "label" => "Approve clarification", "consequence" => "Records canonical intent only; it does not start repair." } ] }
    owner_actions { [ "Review evidence", "Request a separate repair if needed" ] }
    observations { [] }
    last_observed_at { Time.current }
  end
end
