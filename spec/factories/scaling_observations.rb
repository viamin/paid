# frozen_string_literal: true

FactoryBot.define do
  factory :scaling_observation do
    project
    issue { nil }
    sequence(:workflow_id) { |n| "feature-wf-#{n}" }
    workflow_name { "Workflows::FeatureOrchestrationWorkflow" }
    observation_type { "feature_orchestration" }
    status { "completed" }
    success { true }
    parallel_execution { true }
    task_count { 3 }
    dependency_edge_count { 1 }
    parallelizable_group_count { 1 }
    agent_count_planned { 2 }
    agent_count_launched { 2 }
    agent_count_succeeded { 2 }
    agent_count_failed { 0 }
    agent_count_blocked { 0 }
    total_iterations { 4 }
    max_iterations { 2 }
    parallelism_planned { 2 }
    parallelism_observed { 2 }
    batch_count { 2 }
    duration_seconds { 120 }
    total_cost_cents { 300 }
    total_input_tokens { 700 }
    total_output_tokens { 250 }
    metadata { {} }
  end
end
