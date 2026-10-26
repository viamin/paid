# frozen_string_literal: true

FactoryBot.define do
  factory :layered_verification_audit do
    project
    agent_run { association :agent_run, project: project, goal: "layered_verification_audit" }
    trigger_type { "manual_ui" }
    status { "planned" }
    scope_description { "Process a checkout payment." }
    sources { [ { "path" => "docs/intent/payments/payment-specs.md" } ] }
    target_revision { "abc123" }
    budget { { "max_checks" => 1, "max_tokens" => 1_000, "max_duration_seconds" => 60 } }
    plan { {} }
  end
end
