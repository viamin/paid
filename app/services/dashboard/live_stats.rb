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
      active_statuses = AgentRun::ACTIVE_STATUSES
      sanitized_active = active_statuses.map { |s| AgentRun.connection.quote(s) }.join(", ")
      sanitized_today = AgentRun.sanitize_sql_for_conditions([ "?", today ])

      agent_runs.pick(
        Arel.sql("COUNT(*) FILTER (WHERE status IN (#{sanitized_active})) AS active_runs"),
        Arel.sql("COUNT(*) FILTER (WHERE status = 'queued') AS queued_runs"),
        Arel.sql("COUNT(*) FILTER (WHERE status = 'completed' AND completed_at >= #{sanitized_today}) AS completed_today"),
        Arel.sql("COUNT(*) FILTER (WHERE status = 'failed' AND completed_at >= #{sanitized_today}) AS failed_today"),
        Arel.sql("COUNT(*) FILTER (WHERE status = 'running' AND container_id IS NOT NULL) AS active_containers")
      ).then { |values| %w[active_runs queued_runs completed_today failed_today active_containers].zip(values).to_h }
    end

    def agent_runs
      AgentRun.joins(:project).where(projects: { account_id: account.id })
    end
  end
end
