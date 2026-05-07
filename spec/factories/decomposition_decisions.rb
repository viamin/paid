# frozen_string_literal: true

FactoryBot.define do
  factory :decomposition_decision do
    project
    issue { association :issue, project: project }
    sequence(:decision_key) { |n| "workflow-#{n}:planning_outcome:final" }
    workflow_name { "Workflows::PlanningWorkflow" }
    sequence(:workflow_id) { |n| "workflow-#{n}" }
    decision_type { "planning_outcome" }
    outcome { "sub_issues_created" }
    input_context { { "knowledge_results_count" => 2 } }
    plan_data { { "tasks" => [], "created_issues" => [] } }
    hints { { "task_count" => 0 } }
    error_details { {} }
    metadata { { "prompt_source" => "active_prompt" } }
  end
end
