# frozen_string_literal: true

module Runners
  # Determines whether all eligible runners for a run are blocked by
  # time-window restrictions, and if so, returns the earliest time any
  # blocked runner's window opens — so the caller can park the run until
  # then.
  #
  # Returns nil when restrictions are not the sole reason no runner is
  # available (some runners are available, or no eligible runners exist at
  # all). Only returns a Time when every eligible runner is currently
  # time-window-blocked.
  #
  # @spec RUNNER-SCHED-008, RUNNER-SCHED-009
  class TimeWindowPark
    def self.call(agent_run, exclude_runner_ids: [], now: Time.current)
      new(agent_run, exclude_runner_ids: exclude_runner_ids, now: now).earliest_available_at
    end

    def initialize(agent_run, exclude_runner_ids: [], now: Time.current)
      @agent_run = agent_run
      @exclude_runner_ids = Array(exclude_runner_ids)
      @now = now
    end

    def earliest_available_at
      runners = eligible_runners
      return nil if runners.empty?

      # Fast path: if no runner has time restrictions configured, there is
      # nothing to park for. Avoids iterating every runner calling
      # blocked_by_time_window? (which allocates a TimeWindowCheck per call)
      # on the overwhelmingly common path where no restrictions are set.
      return nil unless runners.any? { |r| r[:time_restrictions].present? }

      blocked = runners.select { |r| r.blocked_by_time_window?(now: now) }
      return nil if blocked.empty?

      # If at least one runner is NOT blocked, no parking needed.
      return nil if blocked.size < runners.size

      # All eligible runners are blocked — find the earliest window-open time.
      blocked.filter_map { |r| r.next_time_window_available_at(now: now) }.min
    end

    private

    attr_reader :agent_run, :exclude_runner_ids, :now

    def eligible_runners
      @eligible_runners ||= begin
        owner = agent_run.project&.effective_owner
        return [] unless owner

        owner.runners.kept_only.for_agent_runs
          .where(runner_key: RunnerSupport.container_executable_runner_keys)
          .where.not(id: exclude_runner_ids)
          .to_a
      end
    end
  end
end
