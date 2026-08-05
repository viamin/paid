# frozen_string_literal: true

module Dashboard
  class LiveStats
    CACHE_TTL = 20.seconds

    def self.call(...)
      new(...).call
    end

    def initialize(account:)
      @account = account
    end

    def call
      Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) { build_stats }
    end

    private

    attr_reader :account

    def build_stats
      today = Time.current.beginning_of_day
      run_counts = agent_runs.pick(
        Arel.sql("COUNT(*) FILTER (WHERE status = 'running')"),
        Arel.sql("COUNT(*) FILTER (WHERE status = 'queued' AND temporal_workflow_id IS NULL)"),
        Arel.sql(completed_today_sql(today)),
        Arel.sql(failed_today_sql(today)),
        Arel.sql(active_create_pr_sql)
      )

      {
        active_runs: run_counts[0].to_i,
        queued_runs: run_counts[1].to_i,
        completed_today: run_counts[2].to_i,
        failed_today: run_counts[3].to_i,
        active_create_pr_runs: run_counts[4].to_i,
        max_concurrent_create_pr_runs: account.tenant_max_concurrent_create_pr_runs
      }
    end

    def agent_runs
      @agent_runs ||= AgentRun.excluding_synthetic.joins(:project).where(projects: { account_id: account.id })
    end

    def cache_key
      "dashboard/live_stats/#{account.id}"
    end

    def completed_today_sql(today)
      ActiveRecord::Base.sanitize_sql_array([
        "COUNT(*) FILTER (WHERE status = 'completed' AND completed_at >= ?)",
        today
      ])
    end

    def failed_today_sql(today)
      ActiveRecord::Base.sanitize_sql_array([
        "COUNT(*) FILTER (WHERE status IN (?) AND completed_at >= ?)",
        AgentRun::FAILURE_STATUSES,
        today
      ])
    end

    def active_create_pr_sql
      "COUNT(*) FILTER (WHERE goal = 'create_pr' AND (status = 'running' OR (status = 'queued' AND temporal_workflow_id IS NOT NULL)))"
    end
  end
end
