# frozen_string_literal: true

module ScalingExperiments
  class Create
    DEFAULT_CONTEXT_FILTER = {
      "min_task_count" => 2
    }.freeze
    DEFAULT_TASK_COUNT_BUCKETS = [
      { "label" => "tasks-2-3", "min" => 2, "max" => 3 },
      { "label" => "tasks-4-6", "min" => 4, "max" => 6 },
      { "label" => "tasks-7-plus", "min" => 7 }
    ].freeze

    def self.call(...)
      new(...).call
    end

    def initialize(project:, name:, hypothesis:, values_tested:, control_value:, min_samples_per_value: 2,
      traffic_percentage: 100, context_filter: {}, dimension: "agent_count",
      independent_variables: nil, outcome_metrics: nil, control_definition: nil, cohort_settings: nil)
      @project = project
      @name = name
      @hypothesis = hypothesis
      @values_tested = values_tested
      @control_value = control_value
      @min_samples_per_value = min_samples_per_value
      @traffic_percentage = traffic_percentage
      @context_filter = context_filter
      @dimension = dimension
      @independent_variables = independent_variables
      @outcome_metrics = outcome_metrics
      @control_definition = control_definition
      @cohort_settings = cohort_settings
    end

    def call
      normalized_values = Array(values_tested).map { |value| Integer(value) }.uniq.sort
      normalized_control_value = Integer(control_value)

      ScalingExperiment.create!(
        project: project,
        name: name,
        hypothesis: hypothesis,
        dimension: dimension,
        values_tested: normalized_values,
        control_value: normalized_control_value,
        min_samples_per_value: min_samples_per_value,
        traffic_percentage: traffic_percentage,
        context_filter: normalized_context_filter,
        independent_variables: normalized_independent_variables(normalized_values:, normalized_control_value:),
        outcome_metrics: normalized_outcome_metrics,
        control_definition: normalized_control_definition,
        cohort_settings: normalized_cohort_settings
      )
    end

    private

    attr_reader :project, :name, :hypothesis, :values_tested, :control_value, :min_samples_per_value,
      :traffic_percentage, :context_filter, :dimension, :independent_variables, :outcome_metrics,
      :control_definition, :cohort_settings

    def normalized_context_filter
      DEFAULT_CONTEXT_FILTER.merge((context_filter || {}).deep_stringify_keys)
    end

    def normalized_independent_variables(normalized_values:, normalized_control_value:)
      if independent_variables.present?
        return Array(independent_variables).map { |variable| (variable || {}).deep_stringify_keys }
      end

      [
        {
          "key" => dimension,
          "role" => "primary",
          "values" => normalized_values,
          "control_value" => normalized_control_value,
          "source" => "execution_plan"
        },
        {
          "key" => "task_count",
          "role" => "stratification",
          "source" => "scaling_observations.task_count"
        },
        {
          "key" => "dependency_edge_count",
          "role" => "context",
          "source" => "scaling_observations.dependency_edge_count"
        }
      ]
    end

    def normalized_outcome_metrics
      if outcome_metrics.present?
        return Array(outcome_metrics).map { |metric| (metric || {}).deep_stringify_keys }
      end

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
        },
        {
          "key" => "total_cost_cents",
          "primary" => false,
          "objective" => "minimize",
          "source" => "scaling_observations.total_cost_cents"
        },
        {
          "key" => "agent_launch_success_rate",
          "primary" => false,
          "objective" => "maximize",
          "source" => "scaling_observations.agent_count_succeeded / agent_count_launched"
        },
        {
          "key" => "blocked_task_rate",
          "primary" => false,
          "objective" => "minimize",
          "source" => "scaling_observations.agent_count_blocked / task_count"
        }
      ]
    end

    def normalized_control_definition
      return control_definition.deep_stringify_keys if control_definition.present?

      {
        "baseline_label" => "#{dimension}=#{Integer(control_value)}",
        "comparison_method" => "within_task_count_bucket",
        "fairness_conditions" => [
          "same_project",
          "same_workflow_name",
          "same_observation_type",
          "same_task_count_bucket"
        ],
        "guardrails" => [
          "respect_dependency_order",
          "respect_project_capacity",
          "skip_non_parallel_runs"
        ]
      }
    end

    def normalized_cohort_settings
      return cohort_settings.deep_stringify_keys if cohort_settings.present?

      {
        "assignment_strategy" => "balanced_underfilled",
        "cadence" => "continuous",
        "assignment_unit" => "workflow_id",
        "label_template" => "%<dimension>s-%<value>s__%<task_bucket>s",
        "task_count_buckets" => DEFAULT_TASK_COUNT_BUCKETS
      }
    end
  end
end
