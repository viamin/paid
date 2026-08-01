# frozen_string_literal: true

FactoryBot.define do
  factory :agent_run do
    project
    issue { association :issue, project: project }
    agent_type { "claude_code" }
    focus { "general" }
    status { "queued" }

    trait :queued do
      status { "queued" }
    end

    trait :with_custom_prompt do
      issue { nil }
      custom_prompt { "Make the requested changes" }
    end

    trait :existing_pr do
      source_pull_request_number { 42 }
      custom_prompt { "Fix review comments on PR" }
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

    trait :no_output do
      status { "no_output" }
      started_at { 10.minutes.ago }
      completed_at { Time.current }
      duration_seconds { 600 }
      error_message { "no_changes" }
    end

    trait :failed do
      status { "failed" }
      started_at { 10.minutes.ago }
      completed_at { Time.current }
      duration_seconds { 600 }
      error_message { "An error occurred during execution" }
    end

    trait :paused do
      status { "paused" }
      started_at { 5.minutes.ago }
      paused_at { Time.current }
      guardrail_violation_type { "loop_detected" }
      guardrail_context { { violation_type: "loop_detected", details: "5 consecutive identical outputs" } }
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

    trait :retried do
      status { "retried" }
      started_at { 10.minutes.ago }
      completed_at { Time.current }
      duration_seconds { 600 }
    end

    trait :auth_expired do
      status { "auth_expired" }
      started_at { 10.minutes.ago }
      completed_at { Time.current }
      duration_seconds { 600 }
      error_message { "OAuth session expired" }
      auth_provider { "claude" }
    end

    trait :rate_limited do
      status { "rate_limited" }
      started_at { 10.minutes.ago }
      completed_at { Time.current }
      duration_seconds { 600 }
      error_message { "All runners rate limited: claude_code" }
      rate_limited_until { 2.hours.from_now }
    end

    trait :token_budget_exceeded do
      status { "token_budget_exceeded" }
      started_at { 10.minutes.ago }
      completed_at { Time.current }
      duration_seconds { 600 }
      error_message { "guardrail: token_budget — Run exceeded its per-run input token budget" }
      guardrail_violation_type { "token_budget" }
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

    trait :gemini do
      agent_type { "gemini" }
    end

    trait :opencode do
      agent_type { "opencode" }
    end

    trait :kilocode do
      agent_type { "kilocode" }
    end

    trait :api do
      agent_type { "api" }
    end

    trait :devin do
      agent_type { "devin" }
    end

    trait :factory_tool do
      agent_type { "factory" }
    end

    trait :internal_agent do
      agent_type { "internal_agent" }
    end

    trait :manual do
      trigger_type { "manual" }
    end

    trait :automatic do
      trigger_type { "automatic" }
    end

    trait :create_issue_goal do
      goal { "create_issue" }
      issue { nil }
      custom_prompt { "Create a GitHub issue for the requested task" }
    end

    trait :with_created_issue do
      create_issue_goal
      created_issue_url { "https://github.com/example/repo/issues/42" }
      created_issue_number { 42 }
    end

    trait :with_cross_repo_issue_pair do
      create_issue_goal
      created_issue_url { "https://github.com/example/repo/issues/42" }
      created_issue_number { 42 }
      cross_repo_issues do
        [
          { "repo" => "upstream/dependency", "issue_number" => 10, "issue_url" => "https://github.com/upstream/dependency/issues/10", "role" => "upstream" },
          { "repo" => "example/repo", "issue_number" => 42, "issue_url" => "https://github.com/example/repo/issues/42", "role" => "downstream" }
        ]
      end
    end

    trait :review_goal do
      goal { "review" }
      source_pull_request_number { 10 }
    end

    trait :with_review do
      review_goal
      status { "completed" }
      started_at { 10.minutes.ago }
      completed_at { Time.current }
      duration_seconds { 600 }
      review_url { "https://github.com/example/repo/pull/10#pullrequestreview-123456" }
      review_posted_at { Time.current }
    end

    trait :enhance_issue_goal do
      goal { "enhance_issue" }
    end

    trait :analyze_issue_goal do
      goal { "analyze_issue" }
    end

    trait :lid_planning_goal do
      goal { "lid_planning" }
    end

    trait :external_execution do
      execution_origin { "external" }
      external_source_key { "cursor" }
      external_run_key { "cursor-run-#{SecureRandom.uuid}" }
      adoption_mode_snapshot { "advisory" }
      external_metadata { { "origin" => "import" } }
    end
  end
end
