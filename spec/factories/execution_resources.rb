# frozen_string_literal: true

FactoryBot.define do
  factory :execution_resource do
    account
    project { association :project, account: account }
    agent_run { association :agent_run, project: project }
    resource_type { "environment" }
    state { "active" }
    runner_type { "local_docker" }
    sequence(:identifier) { |n| "resource-#{n}" }
    host { "local" }
    tags { { "paid.agent_run_id" => agent_run.id.to_s, "paid.project_id" => project.id.to_s } }
    metadata { {} }
    reduced_confidence { false }
    cleanup_attempts { 0 }
    runner_handle do
      ExecutionRunners::RunnerHandle.new(
        runner_type: :local_docker,
        identifier: identifier,
        host: host,
        workspace_ref: "paid-workspace-#{agent_run.id}",
        metadata: {
          "agent_run_id" => agent_run.id,
          "worktree_path" => agent_run.worktree_path,
          "environment" => {}
        }
      ).to_storage
    end
  end
end
