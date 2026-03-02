# frozen_string_literal: true

module Dashboard
  class Stats
    attr_reader :account

    def initialize(account:)
      @account = account
    end

    def self.call(...)
      new(...).call
    end

    def call
      {
        run_volume: run_volume,
        duration_percentiles: duration_percentiles,
        cost_and_tokens: cost_and_tokens,
        issue_completion: issue_completion,
        runs_by_agent_type: runs_by_agent_type,
        runs_by_project: runs_by_project
      }
    end

    private

    def agent_runs
      @agent_runs ||= AgentRun.joins(:project).where(projects: { account_id: account.id })
    end

    def issues
      @issues ||= Issue.joins(:project).where(projects: { account_id: account.id })
    end

    def non_pr_issues
      @non_pr_issues ||= issues.where(is_pull_request: false)
    end

    def issue_completion
      total = non_pr_issues.count
      completed = non_pr_issues.where(paid_state: "completed").count
      aggs = issue_completion_aggregates

      {
        total_issues: total,
        completed_count: completed,
        failed_count: non_pr_issues.where(paid_state: "failed").count,
        in_progress_count: non_pr_issues.where(paid_state: "in_progress").count,
        completion_rate: total.zero? ? 0.0 : (completed.to_f / total * 100).round(1),
        runs_per_issue: {
          avg: aggs["avg_runs"].to_f.round(1),
          min: aggs["min_runs"].to_i,
          max: aggs["max_runs"].to_i,
          median: aggs["median_runs"].to_f.round(1)
        },
        time_to_merge: {
          avg: aggs["avg_wall_clock"].to_i,
          p50: aggs["p50_wall_clock"].to_i,
          p90: aggs["p90_wall_clock"].to_i
        },
        agent_minutes: {
          avg: aggs["avg_agent_seconds"].to_i,
          p50: aggs["p50_agent_seconds"].to_i,
          p90: aggs["p90_agent_seconds"].to_i
        }
      }
    end

    def issue_completion_aggregates
      sql = ActiveRecord::Base.sanitize_sql_array([ <<~SQL.squish, account.id ])
        WITH per_issue AS (
          SELECT ar.issue_id,
            COUNT(*) AS run_count,
            COALESCE(SUM(COALESCE(ar.duration_seconds, 0)), 0) AS total_agent_seconds,
            EXTRACT(EPOCH FROM (MAX(i.updated_at) - MIN(ar.created_at))) AS wall_clock_seconds
          FROM agent_runs ar
          JOIN issues i ON i.id = ar.issue_id
          JOIN projects p ON p.id = i.project_id
          WHERE i.is_pull_request = false
            AND i.paid_state = 'completed'
            AND p.account_id = ?
          GROUP BY ar.issue_id
        )
        SELECT
          COALESCE(AVG(run_count), 0) AS avg_runs,
          COALESCE(MIN(run_count), 0) AS min_runs,
          COALESCE(MAX(run_count), 0) AS max_runs,
          COALESCE(percentile_cont(0.5) WITHIN GROUP (ORDER BY run_count), 0) AS median_runs,
          COALESCE(AVG(wall_clock_seconds), 0) AS avg_wall_clock,
          COALESCE(percentile_cont(0.5) WITHIN GROUP (ORDER BY wall_clock_seconds), 0) AS p50_wall_clock,
          COALESCE(percentile_cont(0.9) WITHIN GROUP (ORDER BY wall_clock_seconds), 0) AS p90_wall_clock,
          COALESCE(AVG(total_agent_seconds), 0) AS avg_agent_seconds,
          COALESCE(percentile_cont(0.5) WITHIN GROUP (ORDER BY total_agent_seconds), 0) AS p50_agent_seconds,
          COALESCE(percentile_cont(0.9) WITHIN GROUP (ORDER BY total_agent_seconds), 0) AS p90_agent_seconds
        FROM per_issue
      SQL

      ActiveRecord::Base.connection.select_one(sql)
    end

    def run_volume
      now = Time.current
      {
        total: agent_runs.count,
        last_7_days: agent_runs.where(created_at: (now - 7.days)..now).count,
        last_30_days: agent_runs.where(created_at: (now - 30.days)..now).count,
        active: agent_runs.where(status: %w[queued pending running]).count,
        by_status: agent_runs.group(:status).count,
        failure_rate: failure_rate
      }
    end

    def failure_rate
      completed = agent_runs.where(status: "completed").count
      failed = agent_runs.where(status: "failed").count
      total = completed + failed
      return 0.0 if total.zero?

      (failed.to_f / total * 100).round(1)
    end

    def duration_percentiles
      result = agent_runs.where(status: "completed")
        .where.not(duration_seconds: nil)
        .pick(
          Arel.sql("percentile_cont(0.5) WITHIN GROUP (ORDER BY duration_seconds)"),
          Arel.sql("percentile_cont(0.75) WITHIN GROUP (ORDER BY duration_seconds)"),
          Arel.sql("percentile_cont(0.9) WITHIN GROUP (ORDER BY duration_seconds)"),
          Arel.sql("AVG(duration_seconds)")
        )

      {
        p50: result&.dig(0)&.to_i || 0,
        p75: result&.dig(1)&.to_i || 0,
        p90: result&.dig(2)&.to_i || 0,
        avg: result&.dig(3)&.to_i || 0
      }
    end

    def cost_and_tokens
      now = Time.current
      trailing_30 = agent_runs.where(created_at: (now - 30.days)..now)
      completed_runs = agent_runs.where(status: "completed")
      completed_count = completed_runs.count

      totals = agent_runs.pick(
        Arel.sql("COALESCE(SUM(cost_cents), 0)"),
        Arel.sql("COALESCE(SUM(COALESCE(tokens_input, 0) + COALESCE(tokens_output, 0)), 0)")
      )

      trailing_totals = trailing_30.pick(
        Arel.sql("COALESCE(SUM(cost_cents), 0)"),
        Arel.sql("COALESCE(SUM(COALESCE(tokens_input, 0) + COALESCE(tokens_output, 0)), 0)")
      )

      completed_totals = completed_runs.pick(
        Arel.sql("COALESCE(SUM(cost_cents), 0)"),
        Arel.sql("COALESCE(SUM(COALESCE(tokens_input, 0) + COALESCE(tokens_output, 0)), 0)")
      )

      {
        total_cost_cents: totals[0].to_i,
        total_tokens: totals[1].to_i,
        trailing_30d_cost_cents: trailing_totals[0].to_i,
        trailing_30d_tokens: trailing_totals[1].to_i,
        avg_cost_per_run_cents: completed_count.zero? ? 0 : (completed_totals[0].to_f / completed_count).round,
        avg_tokens_per_run: completed_count.zero? ? 0 : (completed_totals[1].to_f / completed_count).round,
        avg_iterations_per_run: avg_iterations_per_run
      }
    end

    def avg_iterations_per_run
      result = agent_runs.where(status: "completed")
        .where("iterations > 0")
        .pick(Arel.sql("AVG(iterations)"))
      result&.to_f&.round(1) || 0.0
    end

    def runs_by_agent_type
      agent_runs.group(:agent_type).count.sort_by { |_, v| -v }
    end

    def runs_by_project
      agent_runs
        .group("projects.name")
        .count
        .sort_by { |_, v| -v }
        .first(5)
    end
  end
end
