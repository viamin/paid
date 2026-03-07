# frozen_string_literal: true

module Activities
  class CheckRunCapacityActivity < BaseActivity
    activity_name "CheckRunCapacity"

    def execute(input)
      max = UserSetting.maximum(:max_concurrent_runs) || Rails.application.config.x.max_concurrent_runs
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
  end
end
