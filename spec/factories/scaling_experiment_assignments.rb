# frozen_string_literal: true

FactoryBot.define do
  factory :scaling_experiment_assignment do
    scaling_experiment
    project { scaling_experiment.project }
    issue { nil }
    scaling_observation { nil }
    sequence(:workflow_id) { |n| "scaling-workflow-#{n}" }
    assigned_value { 1 }
    outcome_status { "assigned" }
    execution_plan { { "max_batch_size" => assigned_value, "requested_agent_count" => assigned_value } }
    outcome_summary { {} }
  end
end
