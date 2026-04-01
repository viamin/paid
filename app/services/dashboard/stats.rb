# frozen_string_literal: true

module Dashboard
  class Stats
    PHASE_BREAKDOWN_WINDOW = 30.days
    PHASE_BREAKDOWN_RUN_LIMIT = 500

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
        performance_by_outcome: performance_by_outcome,
        performance_by_goal: performance_by_goal,
        runs_by_agent_type: runs_by_agent_type,
        runs_by_provider: runs_by_provider,
        provider_fallback_stats: provider_fallback_stats,
        runs_by_project: runs_by_project,
        cost_by_project: cost_by_project,
        issue_completion: issue_completion
      }
    end

    private

    def effective_provider_sql
      AgentRun.effective_provider_sql
    end

    def normalized_agent_type_sql
      AgentRun.normalized_agent_type_sql
    end

    def normalized_final_provider_sql
      AgentRun.normalize_provider_sql("final_provider")
    end

    def agent_runs
      @agent_runs ||= AgentRun.joins(:project).where(projects: { account_id: account.id })
    end

    def run_volume
      now = Time.current
      {
        total: agent_runs.count,
        last_7_days: agent_runs.where(created_at: (now - 7.days)..now).count,
        last_30_days: agent_runs.where(created_at: (now - 30.days)..now).count,
        active: agent_runs.where(status: AgentRun::UNFINISHED_STATUSES).count,
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
      completed_runs = recent_completed_runs_for_phase_breakdown
      return empty_phase_breakdown if completed_runs.empty?

      values_by_group = Hash.new { |hash, key| hash[key] = [] }

      completed_runs.each do |run|
        phases = run.agent_run_phases.to_a
        next if phases.empty?

        summary = run.phase_summary(phases: phases)
        values_by_group["queue"] << summary[:queue_seconds]

        phase_durations_by_group(phases).each do |phase_group, duration_seconds|
          values_by_group[phase_group] << duration_seconds
        end
      end

      return empty_phase_breakdown if values_by_group.empty?

      phase_breakdown_groups.index_with do |phase_group|
        values = values_by_group.fetch(phase_group, [])
        summarize_phase_values(values)
      end
    end

    def recent_completed_runs_for_phase_breakdown
      now = Time.current

      agent_runs.where(status: "completed", created_at: (now - PHASE_BREAKDOWN_WINDOW)..now)
        .order(created_at: :desc)
        .limit(PHASE_BREAKDOWN_RUN_LIMIT)
        .includes(:agent_run_phases)
        .to_a
    end

    def avg_iterations_per_run
      result = agent_runs.where(status: "completed")
        .where("iterations > 0")
        .pick(Arel.sql("AVG(iterations)"))
      result&.to_f&.round(1) || 0.0
    end

    def performance_by_outcome
      outcome_buckets.index_with do |outcome|
        scope = scoped_by_outcome(outcome)
        build_performance_summary(scope)
      end
    end

    def performance_by_goal
      # Pre-aggregate per (goal, outcome) to avoid N+1 queries.
      finished = agent_runs.finished
      outcome_case = Arel.sql(<<~SQL.squish)
        CASE WHEN status = 'completed' THEN 'completed' ELSE 'other' END
      SQL

      rows = finished
        .group(:goal, outcome_case)
        .pluck(
          :goal,
          outcome_case,
          Arel.sql("COUNT(*)"),
          Arel.sql("COALESCE(SUM(cost_cents), 0)"),
          Arel.sql("COALESCE(SUM(COALESCE(tokens_input, 0) + COALESCE(tokens_output, 0)), 0)"),
          Arel.sql("AVG(duration_seconds)")
        )

      # Index aggregates by [goal, outcome]
      agg = {}
      rows.each do |goal, outcome, count, cost, tokens, avg_dur|
        agg[[ goal, outcome ]] = {
          run_count: count.to_i,
          total_cost_cents: cost.to_i,
          total_tokens: tokens.to_i,
          avg_duration_seconds: avg_dur&.to_i || 0
        }
      end

      AgentRun::GOALS.index_with do |goal|
        # Combine outcome buckets for the overall goal summary
        goal_buckets = outcome_buckets.map { |o| agg[[ goal, o ]] || empty_performance_summary }
        total_count = goal_buckets.sum { |b| b[:run_count] }
        total_cost = goal_buckets.sum { |b| b[:total_cost_cents] }
        total_tokens = goal_buckets.sum { |b| b[:total_tokens] }
        weighted_dur = goal_buckets.sum { |b| b[:avg_duration_seconds] * b[:run_count] }

        overall = if total_count.zero?
          empty_performance_summary
        else
          {
            run_count: total_count,
            total_cost_cents: total_cost,
            avg_cost_cents: (total_cost.to_f / total_count).round,
            total_tokens: total_tokens,
            avg_tokens: (total_tokens.to_f / total_count).round,
            avg_duration_seconds: (weighted_dur.to_f / total_count).to_i
          }
        end

        by_outcome = outcome_buckets.index_with do |outcome|
          bucket = agg[[ goal, outcome ]]
          if bucket.nil? || bucket[:run_count].zero?
            empty_performance_summary
          else
            c = bucket[:run_count]
            bucket.merge(
              avg_cost_cents: (bucket[:total_cost_cents].to_f / c).round,
              avg_tokens: (bucket[:total_tokens].to_f / c).round
            )
          end
        end

        overall.merge(by_outcome: by_outcome)
      end
    end

    def outcome_buckets
      %w[completed other]
    end

    def scoped_by_outcome(outcome, base = agent_runs)
      if outcome == "completed"
        base.where(status: "completed")
      else
        base.where(status: AgentRun::FINISHED_STATUSES - [ "completed" ])
      end
    end

    def build_performance_summary(scope)
      finished = scope.finished
      count = finished.count
      return empty_performance_summary if count.zero?

      totals = finished.pick(
        Arel.sql("COALESCE(SUM(cost_cents), 0)"),
        Arel.sql("COALESCE(SUM(COALESCE(tokens_input, 0) + COALESCE(tokens_output, 0)), 0)"),
        Arel.sql("AVG(duration_seconds)")
      )

      {
        run_count: count,
        total_cost_cents: totals[0].to_i,
        avg_cost_cents: (totals[0].to_f / count).round,
        total_tokens: totals[1].to_i,
        avg_tokens: (totals[1].to_f / count).round,
        avg_duration_seconds: totals[2]&.to_i || 0
      }
    end

    def empty_performance_summary
      {
        run_count: 0,
        total_cost_cents: 0,
        avg_cost_cents: 0,
        total_tokens: 0,
        avg_tokens: 0,
        avg_duration_seconds: 0
      }
    end

    def runs_by_agent_type
      agent_runs.group(:agent_type).count.sort_by { |_, v| -v }
    end

    def runs_by_provider
      agent_runs
        .group(Arel.sql(effective_provider_sql))
        .count
        .sort_by { |_, v| -v }
    end

    def provider_fallback_stats
      total = agent_runs.count
      table = AgentRun.arel_table
      switches = table[:provider_switches].gt(0)
      provider_changed = table[:final_provider].not_eq(nil)
        .and(table[:final_provider].not_eq(""))
        .and(Arel.sql(normalized_final_provider_sql).not_eq(Arel.sql(normalized_agent_type_sql)))
      fallback_runs = agent_runs.where(switches.or(provider_changed))
      fallback_count = fallback_runs.count

      {
        total_runs: total,
        fallback_count: fallback_count,
        fallback_rate: total.zero? ? 0.0 : (fallback_count.to_f / total * 100).round(1),
        by_requested_provider: fallback_runs.group(:agent_type).count.sort_by { |_, v| -v },
        by_effective_provider: fallback_runs
          .group(Arel.sql(effective_provider_sql))
          .count
          .sort_by { |_, v| -v }
      }
    end

    def runs_by_project
      agent_runs
        .group("projects.name")
        .count
        .sort_by { |_, v| -v }
        .first(5)
    end

    def cost_by_project
      Project.where(account_id: account.id)
        .where("total_cost_cents > 0")
        .order(total_cost_cents: :desc)
        .limit(10)
        .pluck(:name, :total_cost_cents)
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
      phase_breakdown_groups.index_with do
        summarize_phase_values([])
      end
    end

    def phase_breakdown_groups
      %w[queue setup prompt agent post cleanup]
    end

    def phase_durations_by_group(phases)
      phases.group_by(&:phase_group).transform_values do |entries|
        entries.sum(&:duration_seconds)
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
