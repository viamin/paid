# frozen_string_literal: true

module Containers
  # Predictive container pool warming based on queued agent run demand.
  #
  # Analyzes upcoming demand (queued runs, scheduled work) and adjusts
  # pool warming targets so containers are ready before runs start.
  # Works alongside PoolManager which handles the actual provisioning.
  #
  # @example
  #   Containers::PoolWarmer.call(project: project)
  class PoolWarmer
    # Scale factor applied to queued run count to determine extra warm targets.
    DEMAND_SCALE_FACTOR = 0.5

    # Maximum additional warm containers beyond the base target.
    MAX_PREDICTIVE_BOOST = 5

    # Minimum queued runs before predictive warming activates.
    MIN_QUEUED_THRESHOLD = 2

    # Recent window for measuring demand velocity (runs queued per hour).
    VELOCITY_WINDOW = 1.hour

    attr_reader :project

    def initialize(project:)
      @project = project
    end

    def self.call(...)
      new(...).call
    end

    def call
      return hold_result unless PoolManager.enabled?
      return hold_result if queued_count < MIN_QUEUED_THRESHOLD

      boost = compute_boost
      return hold_result if boost.zero?

      boosted_target = base_target + boost
      PoolManager.new(project: project, target_size: boosted_target).replenish

      {
        action: :boosted,
        base_target: base_target,
        boost: boost,
        boosted_target: boosted_target,
        queued_count: queued_count,
        velocity: demand_velocity
      }
    end

    private

    def hold_result
      { action: :hold, base_target: base_target, boost: 0, queued_count: queued_count }
    end

    def base_target
      @base_target ||= PoolManager.target_size
    end

    def queued_count
      @queued_count ||= project.agent_runs.waiting.count
    end

    def demand_velocity
      @demand_velocity ||= project.agent_runs.waiting
        .where(created_at: VELOCITY_WINDOW.ago..)
        .count
    end

    def compute_boost
      demand_boost = (queued_count * DEMAND_SCALE_FACTOR).ceil
      velocity_boost = demand_velocity

      [ [ demand_boost, velocity_boost ].max, MAX_PREDICTIVE_BOOST ].min
    end
  end
end
