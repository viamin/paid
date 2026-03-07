# frozen_string_literal: true

module Activities
  class CheckRunCapacityActivity < BaseActivity
    activity_name "CheckRunCapacity"

    def execute(input)
      user = find_user_from_input(input)
      max = AgentRun.effective_max_concurrent_runs(user)
      active_count = AgentRun.active.count
      has_capacity = active_count < max

      logger.info(
        message: "concurrency.capacity_check",
        active_count: active_count,
        max_concurrent_runs: max,
        has_capacity: has_capacity
      )

      { has_capacity: has_capacity, active_count: active_count, max_concurrent_runs: max }
    end

    private

    def find_user_from_input(input)
      project_id = input[:project_id] || input["project_id"]
      return unless project_id

      Project.find_by(id: project_id)&.created_by
    end
  end
end
