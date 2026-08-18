# frozen_string_literal: true

module Capacity
  class ProvisioningRateWindow
    class << self
      def call(...)
        new(...).call
      end

      def recent_starts(window_seconds:, now: Time.current)
        cutoff = now - window_seconds.to_i.seconds

        TenantContext.with_system_access do
          AgentRun.left_outer_joins(:project)
            .where(provisioning_started_at: cutoff..)
            .pluck(Arel.sql("projects.account_id"), :project_id, :provisioning_started_at)
            .map do |account_id, project_id, started_at|
              {
                account_id: account_id,
                project_id: project_id,
                started_at: started_at.in_time_zone
              }
            end
        end
      end
    end

    def initialize(account:, project:, window_seconds:, starts: nil, now: Time.current)
      @account = account
      @project = project
      @window_seconds = window_seconds.to_i
      @starts = starts
      @now = now
    end

    def call
      starts = @starts || self.class.recent_starts(window_seconds:, now:)
      global_count = starts.size
      account_starts = matching_account_starts(starts)
      project_starts = matching_project_starts(starts)

      {
        global_count: global_count,
        account_count: account_starts.size,
        project_count: project_starts.size,
        next_available_at: next_available_at_for(starts),
        account_next_available_at: next_available_at_for(account_starts),
        project_next_available_at: next_available_at_for(project_starts)
      }
    end

    private

    attr_reader :account, :now, :project, :window_seconds

    def matching_account_starts(starts)
      starts.select { |entry| entry[:account_id] == account&.id }
    end

    def matching_project_starts(starts)
      starts.select { |entry| entry[:project_id] == project&.id }
    end

    def next_available_at_for(starts)
      starts.min_by { |entry| entry[:started_at] }&.fetch(:started_at)&.+(window_seconds)
    end
  end
end
