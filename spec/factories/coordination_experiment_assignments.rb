# frozen_string_literal: true

FactoryBot.define do
  factory :coordination_experiment_assignment do
    coordination_experiment
    coordination_experiment_variant do
      association :coordination_experiment_variant, coordination_experiment: coordination_experiment, strategy: :create
    end
    project
    issue { nil }
    sequence(:workflow_id) { |n| "coordination-workflow-#{n}" }
    outcome_status { "assigned" }
    outcome_metrics { {} }
  end
end
