# frozen_string_literal: true

module Dashboard
  class Stats
    CACHE_TTL = 45.seconds
    DAILY_RUN_CHART_WINDOW_DAYS = 30
    DAILY_RUN_CHART_STATUSES = %w[failed completed].freeze
    PHASE_BREAKDOWN_WINDOW = 30.days
    PHASE_BREAKDOWN_RUN_LIMIT = 500

    TIME_RANGES = %w[cumulative 30d 7d 24h].freeze
    VALID_STATUSES = %w[all completed failed].freeze
    VALID_GOALS = %w[all create_pr create_issue review].freeze

    SECTIONS = %i[
      run_volume daily_run_status_chart duration_percentiles duration_trend_chart phase_breakdown cost_and_tokens
      performance_by_outcome performance_by_goal
      runs_by_agent_type runs_by_runner runner_fallback_stats
      runs_by_project cost_by_project issue_completion
    ].freeze

    METRICS_SECTIONS = %i[
      run_volume daily_run_status_chart cost_and_tokens duration_percentiles duration_trend_chart phase_breakdown
      issue_completion cost_by_project runner_fallback_stats
      runs_by_runner runs_by_project
    ].freeze

    PERFORMANCE_SECTIONS = %i[performance_by_outcome performance_by_goal].freeze

    attr_reader :account, :time_range, :status_filter, :goal_filter, :only_sections

    def initialize(account:, time_range: "cumulative", status_filter: "all", goal_filter: "all", only: nil)
      @account = account
      @time_range = TIME_RANGES.include?(time_range) ? time_range : "cumulative"
      @status_filter = VALID_STATUSES.include?(status_filter) ? status_filter : "all"
      @goal_filter = VALID_GOALS.include?(goal_filter) ? goal_filter : "all"
      @only_sections = only
    end

    def self.call(...)
      new(...).call
    end

    def call
      Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) { build_stats }
    end

    private

    def build_stats
      sections = requested_sections
      sections.each_with_object({}) do |section, result|
        result[section] = send(section)
      end
    end

    def effective_runner_sql
      AgentRun.effective_runner_sql
    end

    def normalized_agent_type_sql
      AgentRun.normalized_agent_type_sql
    end

    def normalized_final_runner_sql
      AgentRun.normalize_runner_sql("final_runner")
    end

    def cache_key
      [
        "dashboard/stats",
        account.id,
        time_range,
        status_filter,
        goal_filter,
        requested_sections.join("-"),
        Dashboard::CacheVersion.current(account, scope: Dashboard::CacheVersion::STATS_SCOPE)
      ].join("/")
    end

    def requested_sections
      @requested_sections ||= Array(only_sections).presence || SECTIONS
    end

    def agent_runs
      @agent_runs ||= AgentRun.joins(:project).where(projects: { account_id: account.id })
    end

    def time_filtered_runs
      @time_filtered_runs ||= apply_time_range(agent_runs)
    end

    def performance_filtered_runs
      @performance_filtered_runs ||= begin
        scope = time_filtered_runs
        scope = scope.where(status: status_filter) unless status_filter == "all"
        scope = scope.where(goal: goal_filter) unless goal_filter == "all"
        scope
      end
    end

    def apply_time_range(scope, column: :created_at)
      return scope if time_range == "cumulative"

      cutoff = case time_range
      when "30d" then 30.days.ago
      when "7d" then 7.days.ago
      when "24h" then 24.hours.ago
      end
      scope.where(column => cutoff..)
    end

    def run_volume
      status_counts = time_filtered_runs.group(:status).count
      total = status_counts.values.sum
      trailing_counts = trailing_run_counts
      completed = status_counts.fetch("completed", 0)
      failed = status_counts.fetch("failed", 0)
      finished = completed + failed

      {
        total: total,
        last_7_days: trailing_counts[0].to_i,
        last_30_days: trailing_counts[1].to_i,
        active: AgentRun::UNFINISHED_STATUSES.sum { |status| status_counts.fetch(status, 0) },
        by_status: status_counts,
        failure_rate: finished.zero? ? 0.0 : (failed.to_f / finished * 100).round(1)
      }
    end

    def trailing_run_counts
      now = Time.current

      agent_runs.pick(
        Arel.sql(trailing_count_sql(now - 7.days, now)),
        Arel.sql(trailing_count_sql(now - 30.days, now))
      )
    end

    def duration_percentiles
      result = time_filtered_runs.where(status: "completed")
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

    def duration_trend_chart
      scope = agent_runs
        .where(status: "completed", goal: "create_pr")
        .where.not(duration_seconds: nil, completed_at: nil)

      scope = apply_time_range(scope, column: :completed_at)

      rows = scope
        .group(Arel.sql("DATE(agent_runs.completed_at)"))
        .order(Arel.sql("DATE(agent_runs.completed_at)"))
        .pluck(
          Arel.sql("DATE(agent_runs.completed_at)"),
          Arel.sql("ROUND(AVG(duration_seconds))::integer"),
          Arel.sql("ROUND(percentile_cont(0.5) WITHIN GROUP (ORDER BY duration_seconds))::integer"),
          Arel.sql("COUNT(*)")
        )

      avg_data = {}
      p50_data = {}
      run_counts = {}

      rows.each do |date, avg, p50, count|
        key = date.to_s
        avg_data[key] = avg.to_i
        p50_data[key] = p50.to_i
        run_counts[key] = count.to_i
      end

      trend_data = linear_trend(avg_data)
      slope = trend_slope(avg_data)

      {
        series: [
          { name: "Average", data: avg_data },
          { name: "Median (p50)", data: p50_data },
          { name: "Trend", data: trend_data }
        ],
        run_counts: run_counts,
        slope_seconds_per_day: slope
      }
    end

    def daily_run_status_chart
      start_date = (DAILY_RUN_CHART_WINDOW_DAYS - 1).days.ago.to_date
      end_date = Time.zone.today
      date_range = (start_date..end_date).to_a
      counts = agent_runs.where(created_at: start_date.beginning_of_day..end_date.end_of_day, status: DAILY_RUN_CHART_STATUSES)
        .group(Arel.sql("DATE(agent_runs.created_at)"), :status)
        .count

      DAILY_RUN_CHART_STATUSES.map do |status|
        {
          name: status.titleize,
          data: date_range.index_with { |date| counts.fetch([ date, status ], 0) }
        }
      end
    end

    def cost_and_tokens
      now = Time.current
      totals = time_filtered_runs.pick(
        Arel.sql("COALESCE(SUM(cost_cents), 0)"),
        Arel.sql("COALESCE(SUM(COALESCE(tokens_input, 0) + COALESCE(tokens_output, 0)), 0)"),
        Arel.sql("COALESCE(SUM(cost_cents) FILTER (WHERE status = 'completed'), 0)"),
        Arel.sql(
          "COALESCE(SUM(COALESCE(tokens_input, 0) + COALESCE(tokens_output, 0)) FILTER (WHERE status = 'completed'), 0)"
        ),
        Arel.sql("COUNT(*) FILTER (WHERE status = 'completed')"),
        Arel.sql("COALESCE(AVG(iterations) FILTER (WHERE status = 'completed' AND iterations > 0), 0)")
      )
      trailing_totals = agent_runs.where(created_at: (now - 30.days)..now).pick(
        Arel.sql("COALESCE(SUM(cost_cents), 0)"),
        Arel.sql("COALESCE(SUM(COALESCE(tokens_input, 0) + COALESCE(tokens_output, 0)), 0)")
      )
      completed_count = totals[4].to_i

      {
        total_cost_cents: totals[0].to_i,
        total_tokens: totals[1].to_i,
        trailing_30d_cost_cents: trailing_totals[0].to_i,
        trailing_30d_tokens: trailing_totals[1].to_i,
        avg_cost_per_run_cents: completed_count.zero? ? 0 : (totals[2].to_f / completed_count).round,
        avg_tokens_per_run: completed_count.zero? ? 0 : (totals[3].to_f / completed_count).round,
        avg_iterations_per_run: totals[5].to_f.round(1)
      }
    end

    def phase_breakdown
      rows = ActiveRecord::Base.connection.select_all(phase_breakdown_sql).to_a
      return empty_phase_breakdown if rows.empty?

      rows_by_group = rows.index_by { |row| row.fetch("phase_group") }
      phase_breakdown_groups.index_with { |phase_group| phase_breakdown_summary(rows_by_group[phase_group]) }
    end

    def recent_completed_runs_for_phase_breakdown
      now = Time.current

      time_filtered_runs.where(status: "completed", created_at: (now - PHASE_BREAKDOWN_WINDOW)..now)
        .order(created_at: :desc)
        .limit(PHASE_BREAKDOWN_RUN_LIMIT)
    end

    def phase_breakdown_sql
      selected_runs_sql = recent_completed_runs_for_phase_breakdown.select(:id, :created_at).to_sql

      <<~SQL.squish
        WITH selected_runs AS (
          #{selected_runs_sql}
        ),
        runs_with_phases AS (
          SELECT selected_runs.id,
                 GREATEST(EXTRACT(EPOCH FROM (MIN(agent_run_phases.started_at) - selected_runs.created_at)), 0) AS queue_seconds
          FROM selected_runs
          INNER JOIN agent_run_phases ON agent_run_phases.agent_run_id = selected_runs.id
          GROUP BY selected_runs.id, selected_runs.created_at
        ),
        phase_samples AS (
          SELECT 'queue' AS phase_group, queue_seconds::numeric AS duration_seconds
          FROM runs_with_phases
          UNION ALL
          SELECT agent_run_phases.phase_group, SUM(agent_run_phases.duration_seconds)::numeric AS duration_seconds
          FROM selected_runs
          INNER JOIN agent_run_phases ON agent_run_phases.agent_run_id = selected_runs.id
          GROUP BY selected_runs.id, agent_run_phases.phase_group
        )
        SELECT phase_group,
               ROUND(AVG(duration_seconds))::integer AS avg_seconds,
               ROUND(percentile_cont(0.5) WITHIN GROUP (ORDER BY duration_seconds))::integer AS p50_seconds,
               ROUND(percentile_cont(0.75) WITHIN GROUP (ORDER BY duration_seconds))::integer AS p75_seconds,
               ROUND(percentile_cont(0.9) WITHIN GROUP (ORDER BY duration_seconds))::integer AS p90_seconds,
               COUNT(*)::integer AS sample_size
        FROM phase_samples
        GROUP BY phase_group
      SQL
    end

    def performance_by_outcome
      finished = performance_filtered_runs.finished
      outcome_sql = Arel.sql(<<~SQL.squish)
        CASE WHEN status = 'completed' THEN 'completed' ELSE 'other' END
      SQL

      rows = finished
        .group(outcome_sql)
        .pluck(
          outcome_sql,
          Arel.sql("COUNT(*)"),
          Arel.sql("COALESCE(SUM(cost_cents), 0)"),
          Arel.sql("COALESCE(SUM(COALESCE(tokens_input, 0) + COALESCE(tokens_output, 0)), 0)"),
          Arel.sql("COALESCE(SUM(duration_seconds), 0)"),
          Arel.sql("COUNT(duration_seconds)")
        )

      result = outcome_buckets.index_with { |_| empty_performance_summary }
      rows.each do |outcome, count, cost, tokens, dur_sum, dur_count|
        count = count.to_i
        next if count.zero?

        result[outcome] = {
          run_count: count,
          total_cost_cents: cost.to_i,
          avg_cost_cents: (cost.to_f / count).round,
          total_tokens: tokens.to_i,
          avg_tokens: (tokens.to_f / count).round,
          avg_duration_seconds: dur_count.to_i.zero? ? 0 : (dur_sum.to_f / dur_count.to_i).to_i
        }
      end
      result
    end

    def performance_by_goal
      # Pre-aggregate per (goal, outcome) to avoid N+1 queries.
      finished = performance_filtered_runs.finished
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
          Arel.sql("COALESCE(SUM(duration_seconds), 0)"),
          Arel.sql("COUNT(duration_seconds)")
        )

      # Index aggregates by [goal, outcome]
      agg = {}
      rows.each do |goal, outcome, count, cost, tokens, dur_sum, dur_count|
        agg[[ goal, outcome ]] = {
          run_count: count.to_i,
          total_cost_cents: cost.to_i,
          total_tokens: tokens.to_i,
          total_duration_seconds: dur_sum.to_i,
          duration_count: dur_count.to_i
        }
      end

      AgentRun::GOALS.index_with do |goal|
        # Combine outcome buckets for the overall goal summary
        empty_agg = { run_count: 0, total_cost_cents: 0, total_tokens: 0, total_duration_seconds: 0, duration_count: 0 }
        goal_buckets = outcome_buckets.map { |o| agg[[ goal, o ]] || empty_agg }
        total_count = goal_buckets.sum { |b| b[:run_count] }
        total_cost = goal_buckets.sum { |b| b[:total_cost_cents] }
        total_tokens = goal_buckets.sum { |b| b[:total_tokens] }
        total_dur = goal_buckets.sum { |b| b[:total_duration_seconds] }
        total_dur_count = goal_buckets.sum { |b| b[:duration_count] }

        overall = if total_count.zero?
          empty_performance_summary
        else
          {
            run_count: total_count,
            total_cost_cents: total_cost,
            avg_cost_cents: (total_cost.to_f / total_count).round,
            total_tokens: total_tokens,
            avg_tokens: (total_tokens.to_f / total_count).round,
            avg_duration_seconds: total_dur_count.zero? ? 0 : (total_dur.to_f / total_dur_count).to_i
          }
        end

        by_outcome = outcome_buckets.index_with do |outcome|
          bucket = agg[[ goal, outcome ]]
          if bucket.nil? || bucket[:run_count].zero?
            empty_performance_summary
          else
            c = bucket[:run_count]
            dc = bucket[:duration_count]
            {
              run_count: c,
              total_cost_cents: bucket[:total_cost_cents],
              avg_cost_cents: (bucket[:total_cost_cents].to_f / c).round,
              total_tokens: bucket[:total_tokens],
              avg_tokens: (bucket[:total_tokens].to_f / c).round,
              avg_duration_seconds: dc.zero? ? 0 : (bucket[:total_duration_seconds].to_f / dc).to_i
            }
          end
        end

        overall.merge(by_outcome: by_outcome)
      end
    end

    def outcome_buckets
      %w[completed other]
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
      time_filtered_runs.group(:agent_type).count.sort_by { |_, v| -v }
    end

    def runs_by_runner
      counts_by_runner_label(
        time_filtered_runs
          .group(Arel.sql(effective_runner_sql))
          .count
      )
    end

    def runner_fallback_stats
      rows = time_filtered_runs
        .group(:agent_type, Arel.sql(effective_runner_sql))
        .pluck(
          :agent_type,
          Arel.sql(effective_runner_sql),
          Arel.sql("COUNT(*)"),
          Arel.sql(fallback_count_sql)
        )

      total = 0
      fallback_count = 0
      fallback_by_requested = Hash.new(0)
      fallback_by_effective = Hash.new(0)

      rows.each do |requested_runner, effective_runner, run_count, fallback_run_count|
        run_count = run_count.to_i
        fallback_run_count = fallback_run_count.to_i
        total += run_count
        fallback_count += fallback_run_count
        next if fallback_run_count.zero?

        fallback_by_requested[requested_runner] += fallback_run_count
        fallback_by_effective[effective_runner] += fallback_run_count
      end

      {
        total_runs: total,
        fallback_count: fallback_count,
        fallback_rate: total.zero? ? 0.0 : (fallback_count.to_f / total * 100).round(1),
        by_requested_runner: fallback_by_requested.sort_by { |_, v| -v },
        by_effective_runner: counts_by_runner_label(fallback_by_effective)
      }
    end

    def runs_by_project
      time_filtered_runs
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
      phase_breakdown_groups.index_with { summarize_phase_values([]) }
    end

    def phase_breakdown_groups
      %w[queue setup prompt agent post cleanup]
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

    def phase_breakdown_summary(row)
      return summarize_phase_values([]) if row.nil?

      {
        avg_seconds: row.fetch("avg_seconds", 0).to_i,
        p50_seconds: row.fetch("p50_seconds", 0).to_i,
        p75_seconds: row.fetch("p75_seconds", 0).to_i,
        p90_seconds: row.fetch("p90_seconds", 0).to_i,
        sample_size: row.fetch("sample_size", 0).to_i
      }
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

    def ols_slope(values)
      n = values.size
      sum_x = (0...n).sum
      sum_y = values.sum
      sum_xy = values.each_with_index.sum { |y, i| i * y }
      sum_x2 = (0...n).sum { |i| i * i }
      denom = (n * sum_x2 - sum_x * sum_x).to_f
      return nil if denom.zero?

      (n * sum_xy - sum_x * sum_y) / denom
    end

    def linear_trend(data)
      return {} if data.size < 2

      slope = ols_slope(data.values)
      return {} if slope.nil?

      intercept = (data.values.sum - slope * (0...data.size).sum) / data.size.to_f
      data.keys.each_with_index.each_with_object({}) do |(key, i), result|
        result[key] = [ (intercept + slope * i).round, 0 ].max
      end
    end

    def trend_slope(data)
      return 0.0 if data.size < 2

      ols_slope(data.values)&.round(1) || 0.0
    end

    def trailing_count_sql(start_time, end_time)
      ActiveRecord::Base.sanitize_sql_array([
        "COUNT(*) FILTER (WHERE agent_runs.created_at BETWEEN ? AND ?)",
        start_time,
        end_time
      ])
    end

    def fallback_count_sql
      [
        "COUNT(*) FILTER (WHERE agent_runs.runner_switches > 0 OR (",
        "agent_runs.final_runner IS NOT NULL",
        "AND agent_runs.final_runner <> ''",
        "AND", normalized_final_runner_sql, "<>", normalized_agent_type_sql,
        "))"
      ].join(" ")
    end

    def counts_by_runner_label(counts_by_identifier)
      runners_by_routing_key = runner_records_by_routing_key(counts_by_identifier.keys)

      counts_by_identifier
        .each_with_object(Hash.new(0)) do |(identifier, count), totals|
          totals[runner_label(identifier, runners_by_routing_key[identifier])] += count
        end
        .sort_by { |_, v| -v }
    end

    def runner_records_by_routing_key(identifiers)
      routing_ids = identifiers.filter_map { |identifier| Runner.id_from_routing_key(identifier) }.uniq
      return {} if routing_ids.empty?

      Runner.joins(:user)
              .where(id: routing_ids, users: { account_id: account.id })
              .index_by(&:routing_key)
    end

    def runner_label(identifier, runner_record)
      return runner_record.display_name if runner_record
      return "Deleted runner entry" if Runner.routing_key?(identifier)

      Runner.display_name(RunnerSupport.runner_key_for_agent_type(identifier))
    end
  end
end
