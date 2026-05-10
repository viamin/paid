# frozen_string_literal: true

require "zlib"

module ScalingExperiments
  class Assign
    def self.call(...)
      new(...).call
    end

    def initialize(scaling_experiment:, workflow_id:, task_count:, project:, issue: nil)
      @scaling_experiment = scaling_experiment
      @workflow_id = workflow_id
      @task_count = task_count.to_i
      @project = project
      @issue = issue
    end

    def call
      raise ArgumentError, "scaling experiment is not running" unless scaling_experiment.running?
      return unless scaling_experiment.matches_context?(task_count:)

      existing = ScalingExperimentAssignment.find_by(
        scaling_experiment: scaling_experiment,
        workflow_id: workflow_id
      )
      return existing if existing

      value = select_value
      return unless value

      ScalingExperimentAssignment.create!(
        scaling_experiment: scaling_experiment,
        project: project,
        issue: issue,
        workflow_id: workflow_id,
        assigned_value: value,
        execution_plan: build_execution_plan(value)
      )
    rescue ActiveRecord::RecordNotUnique
      ScalingExperimentAssignment.find_by!(
        scaling_experiment: scaling_experiment,
        workflow_id: workflow_id
      )
    end

    private

    attr_reader :scaling_experiment, :workflow_id, :task_count, :project, :issue

    def select_value
      values = scaling_experiment.eligible_values(task_count:)
      return if values.empty?

      counts = ScalingExperimentAssignment
        .where(scaling_experiment:, assigned_value: values)
        .group(:assigned_value)
        .count
      min_count = values.map { |value| counts.fetch(value, 0) }.min
      candidates = values.select { |value| counts.fetch(value, 0) == min_count }
      candidates[Zlib.crc32("#{scaling_experiment.id}:#{workflow_id}") % candidates.size]
    end

    def build_execution_plan(value)
      plan = {
        "dimension" => scaling_experiment.dimension,
        "dimension_value" => value,
        "task_count" => task_count,
        "cohort_label" => scaling_experiment.cohort_label(task_count:, assigned_value: value),
        "cohort_schedule" => scaling_experiment.cohort_settings.slice("assignment_strategy", "cadence", "assignment_unit"),
        "eligible_values" => scaling_experiment.eligible_values(task_count:),
        "result_capture" => result_capture_plan,
        "safety_limits" => {
          "task_count_cap" => task_count,
          "project_capacity_checked_during_execution" => true,
          "dependency_order_respected" => true
        }
      }

      case scaling_experiment.dimension
      when "agent_count"
        plan.merge!(
          "requested_agent_count" => value,
          "max_batch_size" => value
        )
      when "iteration_count"
        plan.merge!(
          "requested_iteration_count" => value,
          "application_mode" => "task_prompt_budget",
          "prompt_suffix" => iteration_budget_prompt(value)
        )
      when "max_iterations"
        plan["max_iterations_per_agent"] = value
      when "parallelism"
        plan["max_batch_size"] = value
      end

      plan
    end

    def iteration_budget_prompt(value)
      <<~PROMPT.strip
        Iteration budget: aim to complete this task within #{value} agent iterations.
        If you cannot finish safely within that budget, stop and report the blocker instead of continuing indefinitely.
      PROMPT
    end

    def result_capture_plan
      {
        "store_assignment_outcome_summary" => true,
        "observation_scope" => "workflow",
        "child_run_metrics" => %w[
          quality_score
          iterations
          duration_seconds
          cost_cents
          tokens_input
          tokens_output
        ],
        "aggregates" => %w[
          avg_quality_score
          total_iterations
          max_iterations
          duration_seconds
          total_cost_cents
          total_input_tokens
          total_output_tokens
        ]
      }
    end
  end
end
