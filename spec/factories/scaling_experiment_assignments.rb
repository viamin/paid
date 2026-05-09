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
    execution_plan do
      {
        "dimension" => scaling_experiment.dimension,
        "dimension_value" => assigned_value,
        "requested_agent_count" => assigned_value,
        "max_batch_size" => assigned_value,
        "cohort_label" => "agent_count-#{assigned_value}__tasks-2-3"
      }
    end
    outcome_summary { {} }
  end
end
