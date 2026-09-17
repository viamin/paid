# frozen_string_literal: true

FactoryBot.define do
  factory :intent_conformance_verdict do
    project
    issue { association :issue, :pull_request, project: project }
    pr_head_sha { "head0001" }
    approved_design_revision { "abc123superseded" }
    outcome { "within_scope" }
    recorded_at { 1.hour.ago }
    sequence(:reviewer_run_id) { |n| "review-run-#{n}" }
    reviewer_model { "claude-sonnet-4-6" }
    cited_design_claims { [] }
    cited_diff_locations { [] }
    reasoning_summary { "The PR preserves the approved behavior and scope." }
  end
end
