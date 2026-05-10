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
        "plan_version" => 1,
        "scaling_experiment_id" => scaling_experiment.id,
        "workflow_id" => workflow_id,
        "dimension" => scaling_experiment.dimension,
        "dimension_value" => value,
        "dimension_role" => dimension_role(value),
        "control_value" => scaling_experiment.control_value,
        "task_count" => task_count,
        "cohort_label" => scaling_experiment.cohort_label(task_count:, assigned_value: value),
        "cohort_schedule" => scaling_experiment.cohort_settings.slice("assignment_strategy", "cadence", "assignment_unit"),
        "eligible_values" => scaling_experiment.eligible_values(task_count:),
        "safety_limits" => {
          "task_count_cap" => task_count,
          "project_capacity_checked_during_execution" => true,
          "dependency_order_respected" => true,
          "eligible_value_count" => scaling_experiment.eligible_values(task_count:).size
        }
      }

      case scaling_experiment.dimension
      when "agent_count"
        plan.merge!(
          "application_target" => "parallel_execution.max_batch_size",
          "requested_agent_count" => value,
          "max_batch_size" => value,
          "parallel_execution_required" => true
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

    def dimension_role(value)
      value.to_i == scaling_experiment.control_value.to_i ? "control" : "treatment"
    end

    def iteration_budget_prompt(value)
      <<~PROMPT.strip
        Iteration budget: aim to complete this task within #{value} agent iterations.
        If you cannot finish safely within that budget, stop and report the blocker instead of continuing indefinitely.
      PROMPT
    end
  end
end
