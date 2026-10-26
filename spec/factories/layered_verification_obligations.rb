# frozen_string_literal: true

FactoryBot.define do
  factory :layered_verification_obligation do
    project
    framework { "lid" }
    sequence(:external_identity) { |n| "PAYMENTS-#{n}" }
    external_revision { "abc123" }
    scope_description { "Process a checkout payment." }
    approval_state { "proposed" }

    trait :offered_cir do
      framework { "paid_offered_cir" }
      approval_state { "proposed" }
      sequence(:external_identity) { |n| ".okf/cir/checkout-#{n}.md" }
    end
  end

  factory :layered_verification_finding do
    project
    obligation { association :layered_verification_obligation, project: project }
    agent_run { association :agent_run, project: project, goal: "layered_verification_audit" }
    cause_signature { "missing-correspondence" }
    status { "open" }
    source_passages { [ "docs/intent/example.md#L1" ] }
    observed_behavior { { "summary" => "Observed behavior" } }
    check_limitations { [ "No runtime evidence" ] }
  end
end
