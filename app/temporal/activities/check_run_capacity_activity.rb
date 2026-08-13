# frozen_string_literal: true

module Activities
  class CheckRunCapacityActivity < BaseActivity
    activity_name "CheckRunCapacity"

    def execute(input)
      user = find_user_from_input(input)
      project = Project.find_by(id: input[:project_id]) if input[:project_id]

      unless user
        logger.warn(
          message: "concurrency.owner_not_found",
          project_id: input[:project_id]
        ) if input[:project_id]

        return {
          has_capacity: false,
          user_active_count: nil,
          max_concurrent_runs: nil,
          effective_max_concurrent_runs: nil,
          reason: "owner_not_found"
        }
      end

      admission = Capacity::RunAdmission.call(
        user: user,
        project: project,
        goal: input[:goal]
      )

      logger.info(
        message: "concurrency.capacity_check",
        user_active_count: admission[:user_active_count],
        max_concurrent_runs: admission[:effective_max_concurrent_runs],
        global_active_count: admission[:global_active_count],
        global_max_concurrent_executions: admission[:global_max_concurrent_executions],
        has_capacity: admission[:allowed],
        reason: admission[:reason],
        mode: admission[:mode],
        available_memory_bytes: admission[:available_memory_bytes]
      )

      {
        has_capacity: admission[:allowed],
        user_active_count: admission[:user_active_count],
        max_concurrent_runs: admission[:effective_max_concurrent_runs],
        effective_max_concurrent_runs: admission[:effective_max_concurrent_runs],
        global_active_count: admission[:global_active_count],
        global_max_concurrent_executions: admission[:global_max_concurrent_executions],
        global_available_slots: admission[:global_available_slots],
        reason: admission[:reason],
        available_memory_bytes: admission[:available_memory_bytes]
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
