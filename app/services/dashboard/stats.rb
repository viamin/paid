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
        phase_breakdown: phase_breakdown,
        cost_and_tokens: cost_and_tokens,
        runs_by_agent_type: runs_by_agent_type,
        runs_by_project: runs_by_project,
        issue_completion: issue_completion
      }
    end

    private

    def agent_runs
      @agent_runs ||= AgentRun.joins(:project).where(projects: { account_id: account.id })
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

    def phase_breakdown
      completed_runs = agent_runs.where(status: "completed").includes(:agent_run_phases).to_a
      return empty_phase_breakdown if completed_runs.empty?

      values_by_group = Hash.new { |hash, key| hash[key] = [] }

      completed_runs.each do |run|
        summary = run.phase_summary
        values_by_group["queue"] << summary[:queue_seconds]
        values_by_group["setup"] << summary[:setup_seconds]
        values_by_group["prompt"] << summary[:prompt_seconds]
        values_by_group["agent"] << summary[:agent_seconds]
        values_by_group["post"] << summary[:post_seconds]
        values_by_group["cleanup"] << summary[:cleanup_seconds]
      end

      values_by_group.transform_values do |values|
        summarize_phase_values(values)
      end
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

    def issue_completion
      result = merged_pr_aggregate
      return empty_issue_completion if result.nil? || result["merged_count"].to_i.zero?

      {
        merged_count: result["merged_count"].to_i,
        runs_per_issue: {
          avg: result["avg_runs"]&.to_f&.round(1) || 0.0,
          min: result["min_runs"]&.to_i || 0,
          max: result["max_runs"]&.to_i || 0,
          median: result["median_runs"]&.to_f&.round(1) || 0.0
        },
        time_to_merge: {
          avg_seconds: result["avg_wall_seconds"]&.to_f&.round || 0,
          p50_seconds: result["p50_wall_seconds"]&.to_f&.round || 0,
          p90_seconds: result["p90_wall_seconds"]&.to_f&.round || 0
        },
        agent_run_seconds: {
          avg_seconds: result["avg_run_seconds"]&.to_f&.round || 0,
          p50_seconds: result["p50_run_seconds"]&.to_f&.round || 0,
          p90_seconds: result["p90_run_seconds"]&.to_f&.round || 0
        }
      }
    end

    def empty_issue_completion
      {
        merged_count: 0,
        runs_per_issue: { avg: 0.0, min: 0, max: 0, median: 0.0 },
        time_to_merge: { avg_seconds: 0, p50_seconds: 0, p90_seconds: 0 },
        agent_run_seconds: { avg_seconds: 0, p50_seconds: 0, p90_seconds: 0 }
      }
    end

    def empty_phase_breakdown
      %w[queue setup prompt agent post cleanup].index_with do
        summarize_phase_values([])
      end
    end

    def summarize_phase_values(values)
      sorted = values.compact.sort
      count = sorted.length

      {
        avg_seconds: count.zero? ? 0 : (sorted.sum.to_f / count).round,
        p50_seconds: percentile(sorted, 0.5),
        p75_seconds: percentile(sorted, 0.75),
        p90_seconds: percentile(sorted, 0.9),
        sample_size: count
      }
    end

    def percentile(sorted_values, percentile)
      return 0 if sorted_values.empty?

      rank = (percentile * (sorted_values.length - 1))
      lower = sorted_values[rank.floor]
      upper = sorted_values[rank.ceil]
      interpolated = lower + ((upper - lower) * (rank - rank.floor))
      interpolated.round
    end

    def merged_pr_aggregate
      project_ids_sql = Project.where(account_id: account.id).select(:id).to_sql

      # NOTE: github_updated_at is a proxy for merge time since there is no
      # dedicated merged_at column yet. It can drift when a PR is updated
      # after merge (comments, labels, etc.). A future migration should add
      # issues.merged_at populated by MergePullRequestActivity (#230).
      sql = <<~SQL.squish
        WITH per_issue AS (
          SELECT issues.id,
                 COUNT(agent_runs.id) AS run_count,
                 EXTRACT(EPOCH FROM issues.github_updated_at
                   - MIN(COALESCE(agent_runs.started_at, agent_runs.created_at))) AS wall_seconds,
                 COALESCE(SUM(agent_runs.duration_seconds), 0) AS total_run_seconds
          FROM issues
          INNER JOIN agent_runs ON agent_runs.issue_id = issues.id
          WHERE issues.is_pull_request = true
            AND issues.pr_review_phase = 'merged'
            AND issues.project_id IN (#{project_ids_sql})
            AND agent_runs.goal = 'create_pr'
            AND COALESCE(agent_runs.started_at, agent_runs.created_at) <= issues.github_updated_at
          GROUP BY issues.id, issues.github_updated_at
        )
        SELECT COUNT(*) AS merged_count,
               AVG(run_count) AS avg_runs,
               MIN(run_count) AS min_runs,
               MAX(run_count) AS max_runs,
               percentile_cont(0.5) WITHIN GROUP (ORDER BY run_count) AS median_runs,
               AVG(wall_seconds) AS avg_wall_seconds,
               percentile_cont(0.5) WITHIN GROUP (ORDER BY wall_seconds) AS p50_wall_seconds,
               percentile_cont(0.9) WITHIN GROUP (ORDER BY wall_seconds) AS p90_wall_seconds,
               AVG(total_run_seconds) AS avg_run_seconds,
               percentile_cont(0.5) WITHIN GROUP (ORDER BY total_run_seconds) AS p50_run_seconds,
               percentile_cont(0.9) WITHIN GROUP (ORDER BY total_run_seconds) AS p90_run_seconds
        FROM per_issue
      SQL

      ActiveRecord::Base.connection.select_one(sql)
    end
  end
end
