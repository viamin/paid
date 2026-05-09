# frozen_string_literal: true

FactoryBot.define do
  factory :scaling_experiment do
    project
    sequence(:name) { |n| "Scaling Experiment #{n}" }
    hypothesis { "Success improves as agent count increases before diminishing returns appear." }
    dimension { "agent_count" }
    values_tested { [ 1, 2, 4 ] }
    control_value { 1 }
    context_filter { { "min_task_count" => 2 } }
    independent_variables do
      [
        {
          "key" => dimension,
          "role" => "primary",
          "values" => values_tested,
          "control_value" => control_value,
          "source" => "execution_plan"
        },
        {
          "key" => "task_count",
          "role" => "stratification",
          "source" => "scaling_observations.task_count"
        }
      ]
    end
    outcome_metrics do
      [
        {
          "key" => "success_rate",
          "primary" => true,
          "objective" => "maximize",
          "source" => "scaling_observations.success"
        },
        {
          "key" => "duration_seconds",
          "primary" => false,
          "objective" => "minimize",
          "source" => "scaling_observations.duration_seconds"
        }
      ]
    end
    control_definition do
      {
        "comparison_method" => "within_task_count_bucket",
        "fairness_conditions" => [ "same_project", "same_task_count_bucket" ],
        "guardrails" => [ "respect_dependency_order", "skip_non_parallel_runs" ]
      }
    end
    cohort_settings do
      {
        "assignment_strategy" => "balanced_underfilled",
        "cadence" => "continuous",
        "assignment_unit" => "workflow_id",
        "label_template" => "%<dimension>s-%<value>s__%<task_bucket>s",
        "task_count_buckets" => [
          { "label" => "tasks-2-3", "min" => 2, "max" => 3 },
          { "label" => "tasks-4-6", "min" => 4, "max" => 6 },
          { "label" => "tasks-7-plus", "min" => 7 }
        ]
      }
    end
    status { "running" }
    min_samples_per_value { 2 }
    traffic_percentage { 100 }
  end
end
