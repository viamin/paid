# frozen_string_literal: true

module Activities
  class CheckRunCapacityActivity < BaseActivity
    activity_name "CheckRunCapacity"

    def execute(input)
      user = find_user_from_input(input)

      if user
        user_active_count = AgentRun.active_count_for_user(user)
        max_concurrent_runs = user.settings.max_concurrent_runs
        has_capacity = user_active_count < max_concurrent_runs
      else
        # Fail closed: if we can't resolve an owner, don't allow the run.
        user_active_count = nil
        max_concurrent_runs = nil
        has_capacity = false

        if input[:project_id]
          logger.warn(
            message: "concurrency.owner_not_found",
            project_id: input[:project_id]
          )
        end
      end

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
