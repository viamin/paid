# frozen_string_literal: true

module Dashboard
  class LiveStats
    def self.call(...)
      new(...).call
    end

    def initialize(account:)
      @account = account
    end

    def call
      counts = agent_runs.pick(
        Arel.sql("COUNT(*) FILTER (WHERE status IN (#{active_statuses_sql}))"),
        Arel.sql("COUNT(*) FILTER (WHERE status = 'queued')"),
        Arel.sql("COUNT(*) FILTER (WHERE status = 'completed' AND completed_at >= #{today_sql})"),
        Arel.sql("COUNT(*) FILTER (WHERE status IN ('failed', 'timeout', 'auth_expired', 'rate_limited') AND completed_at >= #{today_sql})"),
        Arel.sql("COUNT(*) FILTER (WHERE status = 'running' AND container_id IS NOT NULL)")
      )

      {
        active_runs: counts[0].to_i,
        queued_runs: counts[1].to_i,
        completed_today: counts[2].to_i,
        failed_today: counts[3].to_i,
        active_containers: counts[4].to_i,
        total_projects: account.projects.count,
        active_projects: account.projects.active.count
      }
    end

    private

    attr_reader :account

    def agent_runs
      @agent_runs ||= AgentRun.joins(:project).where(projects: { account_id: account.id })
    end

    def active_statuses_sql
      AgentRun::ACTIVE_STATUSES.map do |status|
        ActiveRecord::Base.connection.quote(status)
      end.join(", ")
    end

    def today_sql
      ActiveRecord::Base.connection.quote(Time.current.beginning_of_day)
    end
  end
end
