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

      max_parallel = user.settings.max_parallel_agents_per_project
      active_count = AgentRun.active_count_for_project(project)
      available_slots = [ max_parallel - active_count, 0 ].max

      # Also check user-level capacity
      user_active_count = AgentRun.active_count_for_user(user)
      user_max = user.settings.max_concurrent_runs
      user_available = [ user_max - user_active_count, 0 ].max

      effective_slots = [ available_slots, user_available ].min

      logger.info(
        message: "concurrency.project_capacity_check",
        project_id: input[:project_id],
        active_count: active_count,
        max_parallel: max_parallel,
        user_active_count: user_active_count,
        user_max: user_max,
        effective_slots: effective_slots
      )

      {
        has_capacity: effective_slots > 0,
        available_slots: effective_slots,
        project_active_count: active_count,
        max_parallel_per_project: max_parallel,
        user_active_count: user_active_count,
        max_concurrent_runs: user_max,
        pr_aggregation_enabled: project.pr_aggregation_enabled?
      }
    end
  end
end
