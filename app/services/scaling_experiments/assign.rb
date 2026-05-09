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
      {
        "dimension" => scaling_experiment.dimension,
        "requested_agent_count" => value,
        "max_batch_size" => value,
        "task_count" => task_count,
        "eligible_values" => scaling_experiment.eligible_values(task_count:),
        "safety_limits" => {
          "task_count_cap" => task_count,
          "project_capacity_checked_during_execution" => true,
          "dependency_order_respected" => true
        }
      }
    end
  end
end
