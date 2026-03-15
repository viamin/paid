# frozen_string_literal: true

module Activities
  class CheckRunCapacityActivity < BaseActivity
    activity_name "CheckRunCapacity"

    def execute(input)
      user = find_user_from_input(input)
      has_capacity = AgentRun.has_run_capacity?(user: user)
      user_active_count = user ? AgentRun.active_count_for_user(user) : nil
      max_concurrent_runs = user&.settings&.max_concurrent_runs

      logger.info(
        message: "concurrency.capacity_check",
        user_active_count: user_active_count,
        max_concurrent_runs: max_concurrent_runs,
        has_capacity: has_capacity
      )

      {
        has_capacity: has_capacity,
        user_active_count: user_active_count,
        max_concurrent_runs: max_concurrent_runs
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
