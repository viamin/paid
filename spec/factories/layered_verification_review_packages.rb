# frozen_string_literal: true

FactoryBot.define do
  factory :layered_verification_review_package do
    project
    agent_run { association :agent_run, project:, goal: "layered_verification_audit" }
    sequence(:package_digest) { |n| format("%064x", n) }
    revision_number { 1 }
    bound_inputs do
      { "agent_run_id" => agent_run.id, "target_revision" => "abc123", "obligations" => [],
        "plan_revision" => format("%064x", 1), "check_result_ids" => [], "approval_ids" => [],
        "inbox_decisions" => [] }
    end
  end

  factory :layered_verification_review_approval do
    package { association :layered_verification_review_package }
    approved_by { association :user, :owner, account: package.project.account }
    approved_at { Time.current }
    provenance { { "surface" => "spec" } }
  end
end
