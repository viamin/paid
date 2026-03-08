# frozen_string_literal: true

module Activities
  class CheckRunCapacityActivity < BaseActivity
    activity_name "CheckRunCapacity"

    def execute(input)
      user = find_user_from_input(input)
      system_max = AgentRun.effective_max_concurrent_runs
      global_active_count = AgentRun.active.count
      user_active_count = nil
      user_max = nil

      if user
        user_active_count = AgentRun.active_count_for_user(user)
        user_max = AgentRun.effective_max_concurrent_runs(user)
        has_capacity = global_active_count < system_max && user_active_count < user_max
      else
        has_capacity = global_active_count < system_max
      end

      logger.info(
        message: "concurrency.capacity_check",
        global_active_count: global_active_count,
        user_active_count: user_active_count,
        max_concurrent_runs: user_max || system_max,
        has_capacity: has_capacity
      )

      {
        has_capacity: has_capacity,
        global_active_count: global_active_count,
        user_active_count: user_active_count,
        max_concurrent_runs: user_max || system_max
      }
    end

    private

    # BaseActivity normalizes Temporal inputs to symbol-keyed hashes
    def find_user_from_input(input)
      project_id = input[:project_id]
      return unless project_id

      Project.find_by(id: project_id)&.effective_owner
    end
  end
end
