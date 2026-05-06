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
      base = agent_runs
      pool_metrics = Containers::PoolManager.metrics(projects: account.projects)
      run_counts = base.pick(
        Arel.sql("COUNT(*) FILTER (WHERE status = 'running')"),
        Arel.sql("COUNT(*) FILTER (WHERE status = 'queued' AND temporal_workflow_id IS NULL)"),
        Arel.sql(completed_today_sql(today)),
        Arel.sql(failed_today_sql(today)),
        Arel.sql("COUNT(DISTINCT container_id) FILTER (WHERE status = 'running' AND container_id IS NOT NULL)")
      )
      project_counts = account.projects.pick(
        Arel.sql("COUNT(*)"),
        Arel.sql("COUNT(*) FILTER (WHERE active)")
      )

      {
        active_runs: run_counts[0].to_i,
        queued_runs: run_counts[1].to_i,
        completed_today: run_counts[2].to_i,
        failed_today: run_counts[3].to_i,
        active_containers: run_counts[4].to_i,
        warm_containers: pool_metrics[:warm],
        pool_target: pool_metrics[:target],
        total_projects: project_counts[0].to_i,
        active_projects: project_counts[1].to_i
      }
    end

    def agent_runs
      @agent_runs ||= AgentRun.joins(:project).where(projects: { account_id: account.id })
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
  end
end
