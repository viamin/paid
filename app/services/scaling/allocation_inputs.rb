# frozen_string_literal: true

module Scaling
  class AllocationInputs
    STALE_THRESHOLD_SECONDS = 7.days.to_i

    attr_reader :task_count, :budget_cents, :max_agent_count, :max_duration_seconds,
                :dependency_edge_count, :parallelizable_group_count

    def initialize(
      task_count:,
      budget_cents: 0,
      max_agent_count: 8,
      max_duration_seconds: 0,
      dependency_edge_count: 0,
      parallelizable_group_count: 0
    )
      @task_count = Integer(task_count)
      @budget_cents = Integer(budget_cents)
      @max_agent_count = Integer(max_agent_count)
      @max_duration_seconds = Integer(max_duration_seconds)
      @dependency_edge_count = Integer(dependency_edge_count)
      @parallelizable_group_count = Integer(parallelizable_group_count)

      validate!
      freeze
    end

    def budget_constrained?
      budget_cents.positive?
    end

    def time_constrained?
      max_duration_seconds.positive?
    end

    def parallelism_potential
      return 0.0 if task_count.zero?

      parallelizable_group_count.to_f / task_count
    end

    def complexity_score
      return 0.0 if task_count.zero?

      edge_density = dependency_edge_count.to_f / task_count
      parallelism_potential * 0.4 + edge_density * 0.3 + (1.0 / task_count) * 0.3
    end

    private

    def validate!
      raise ArgumentError, "task_count must be positive" unless task_count.positive?
      raise ArgumentError, "budget_cents must be non-negative" if budget_cents.negative?
      raise ArgumentError, "max_agent_count must be positive" unless max_agent_count.positive?
      raise ArgumentError, "max_duration_seconds must be non-negative" if max_duration_seconds.negative?
      raise ArgumentError, "dependency_edge_count must be non-negative" if dependency_edge_count.negative?
      raise ArgumentError, "parallelizable_group_count must be non-negative" if parallelizable_group_count.negative?
    end
  end
end
