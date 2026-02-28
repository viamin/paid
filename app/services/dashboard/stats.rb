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
        runs_by_agent_type: runs_by_agent_type,
        runs_by_project: runs_by_project
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
