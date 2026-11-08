# frozen_string_literal: true

# @spec TRUSTED-MEASUREMENTS-001
FactoryBot.define do
  factory :trusted_measurement_attempt do
    account { project.account }
    project
    issue { association :issue, project: }
    external_issue_number { issue&.github_number || 4812 }
    criterion_key { "closed_planning_hold_notifications_cleared" }
    check_key { "agent_planning_hold_reconciliation_closed_count" }
    check_version { 1 }
    deployed_revision { "abc123" }
    status { "pending" }
    result { {} }

    trait :succeeded do
      status { "succeeded" }
      result { { "active_total" => 0, "active_closed_issue_count" => 0, "baseline" => 36, "target" => 0 } }
      executed_at { Time.current }
    end

    trait :unknown do
      status { "unknown" }
      deployed_revision { nil }
      failure_reason { "missing_deployment_signal" }
      executed_at { Time.current }
    end

    trait :failed do
      status { "failed" }
      failure_reason { "boom" }
      executed_at { Time.current }
    end
  end
end
