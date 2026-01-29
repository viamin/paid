# frozen_string_literal: true

FactoryBot.define do
  factory :agent_run do
    project
    agent_type { "claude_code" }
    status { "pending" }

    trait :with_issue do
      issue { association :issue, project: project }
    end

    trait :running do
      status { "running" }
      started_at { 5.minutes.ago }
    end

    trait :completed do
      status { "completed" }
      started_at { 10.minutes.ago }
      completed_at { Time.current }
      duration_seconds { 600 }
      result_commit_sha { "abc123def456789012345678901234567890abcd" }
      pull_request_url { "https://github.com/example/repo/pull/1" }
      pull_request_number { 1 }
    end

    trait :failed do
      status { "failed" }
      started_at { 10.minutes.ago }
      completed_at { Time.current }
      duration_seconds { 600 }
      error_message { "An error occurred during execution" }
    end

    trait :cancelled do
      status { "cancelled" }
      started_at { 5.minutes.ago }
      completed_at { Time.current }
      duration_seconds { 300 }
    end

    trait :timeout do
      status { "timeout" }
      started_at { 1.hour.ago }
      completed_at { Time.current }
      duration_seconds { 3600 }
    end

    trait :with_temporal do
      temporal_workflow_id { "workflow-#{SecureRandom.uuid}" }
      temporal_run_id { "run-#{SecureRandom.uuid}" }
    end

    trait :with_git_context do
      worktree_path { "/var/paid/worktrees/project-123" }
      branch_name { "agent/feature-implementation" }
      base_commit_sha { "0123456789abcdef0123456789abcdef01234567" }
    end

    trait :with_metrics do
      iterations { 5 }
      tokens_input { 10000 }
      tokens_output { 5000 }
      cost_cents { 150 }
    end

    trait :cursor do
      agent_type { "cursor" }
    end

    trait :codex do
      agent_type { "codex" }
    end

    trait :copilot do
      agent_type { "copilot" }
    end

    trait :api do
      agent_type { "api" }
    end
  end
end
