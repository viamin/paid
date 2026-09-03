# frozen_string_literal: true

module Activities
  # Checks whether a project has capacity for additional parallel agent runs.
  # Returns the number of available slots based on the project owner's
  # max_parallel_agents_per_project setting and current active run count.
  class CheckProjectRunCapacityActivity < BaseActivity
    activity_name "CheckProjectRunCapacity"

    def execute(input)
      project = Project.find_by(id: input[:project_id])
      unless project
        return { has_capacity: false, available_slots: 0, error: "project_not_found" }
      end

      user = project.effective_owner
      unless user
        logger.warn(
          message: "concurrency.project_owner_not_found",
          project_id: input[:project_id]
        )
        return { has_capacity: false, available_slots: 0, error: "owner_not_found" }
      end

      admission = Capacity::RunAdmission.call(
        user: user,
        project: project,
        goal: input[:goal]
      )
      max_parallel = user.settings.max_parallel_agents_per_project

      logger.info(
        message: "concurrency.project_capacity_check",
        project_id: input[:project_id],
        active_count: admission[:project_active_count],
        max_parallel: max_parallel,
        user_active_count: admission[:user_active_count],
        user_max: admission[:effective_max_concurrent_runs],
        effective_slots: admission[:available_slots],
        reason: admission[:reason],
        mode: admission[:mode],
        available_memory_bytes: admission[:available_memory_bytes]
      )

      {
        has_capacity: admission[:available_slots] > 0,
        available_slots: admission[:available_slots],
        project_active_count: admission[:project_active_count],
        max_parallel_per_project: max_parallel,
        user_active_count: admission[:user_active_count],
        max_concurrent_runs: admission[:effective_max_concurrent_runs],
        effective_max_concurrent_runs: admission[:effective_max_concurrent_runs],
        reason: admission[:reason],
        available_memory_bytes: admission[:available_memory_bytes]
      }
    end
  end
end
