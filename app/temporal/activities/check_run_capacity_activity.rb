# frozen_string_literal: true

module Activities
  class CheckRunCapacityActivity < BaseActivity
    activity_name "CheckRunCapacity"

    def execute(input)
      user = find_user_from_input(input)
      system_max = AgentRun.effective_max_concurrent_runs
      global_active_count = AgentRun.active.count

      if user
        user_project_ids = Project.where(created_by: user).select(:id)
        active_count = AgentRun.active.where(project_id: user_project_ids).count
        max = AgentRun.effective_max_concurrent_runs(user)
        has_capacity = global_active_count < system_max && active_count < max
      else
        active_count = global_active_count
        max = system_max
        has_capacity = active_count < max
      end

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
