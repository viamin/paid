# frozen_string_literal: true

module Capacity
  class ProvisioningRateWindow
    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(account:, project:, window_seconds:, now: Time.current)
      @account = account
      @project = project
      @window_seconds = window_seconds.to_i
      @now = now
    end

    def call
      starts = recent_starts

      {
        global_count: starts.size,
        account_count: starts.count { |entry| entry[:account_id] == account&.id },
        project_count: starts.count { |entry| entry[:project_id] == project&.id },
        next_available_at: starts.min_by { |entry| entry[:started_at] }&.fetch(:started_at)&.+(window_seconds)
      }
    end

    private

    attr_reader :account, :now, :project, :window_seconds

    def recent_starts
      cutoff = now - window_seconds.seconds

      TenantContext.with_system_access do
        AgentRun.includes(:project)
          .where.not("COALESCE(external_metadata ->> 'provisioning_started_at', '') = ''")
          .filter_map do |run|
            started_at = Time.zone.parse(run.external_metadata["provisioning_started_at"].to_s)
            next unless started_at && started_at >= cutoff

            {
              account_id: run.project&.account_id,
              project_id: run.project_id,
              started_at: started_at
            }
          end
      end
    end
  end
end
