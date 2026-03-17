# frozen_string_literal: true

module Dashboard
  class LiveStats
    attr_reader :account

    def initialize(account:)
      @account = account
    end

    def self.call(...)
      new(...).call
    end

    def call
      counts = agent_run_counts
      {
        active_runs: counts["active_runs"] || 0,
        queued_runs: counts["queued_runs"] || 0,
        completed_today: counts["completed_today"] || 0,
        failed_today: counts["failed_today"] || 0,
        active_containers: counts["active_containers"] || 0,
        total_projects: account.projects.count,
        active_projects: account.projects.active.count
      }
    end

    private

    def agent_run_counts
      today = Time.current.beginning_of_day
      quoted_today = AgentRun.connection.quote(today)
      active_in = AgentRun.active.where_values_hash["status"].map { |s| AgentRun.connection.quote(s) }.join(", ")

      agent_runs.pick(
        Arel.sql("COUNT(*) FILTER (WHERE status IN (#{active_in})) AS active_runs"),
        Arel.sql("COUNT(*) FILTER (WHERE status = 'queued') AS queued_runs"),
        Arel.sql("COUNT(*) FILTER (WHERE status = 'completed' AND completed_at >= #{quoted_today}) AS completed_today"),
        Arel.sql("COUNT(*) FILTER (WHERE status = 'failed' AND completed_at >= #{quoted_today}) AS failed_today"),
        Arel.sql("COUNT(*) FILTER (WHERE status = 'running' AND container_id IS NOT NULL) AS active_containers")
      ).then { |values| %w[active_runs queued_runs completed_today failed_today active_containers].zip(values).to_h }
    end

    def agent_runs
      AgentRun.joins(:project).where(projects: { account_id: account.id })
    end
  end
end
