# frozen_string_literal: true

module Providers
  class UsageStats
    CACHE_TTL = 15.minutes

    attr_reader :user

    def initialize(user:)
      @user = user
    end

    def self.call(...)
      new(...).call
    end

    def call
      Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) { build_stats }
    end

    private

    def cache_key
      "providers/usage_stats/#{user.account_id}"
    end

    def build_stats
      seven_day_runs = time_filtered_runs(7.days.ago)
      seven_day_token_data = token_data_by_provider(7.days.ago)
      attempt_metrics = provider_attempt_metrics(7.days.ago)

      run_counts = seven_day_runs.group(Arel.sql(effective_provider_sql)).count
      cost_by_provider = seven_day_token_data[:cost]
      tokens_by_provider = seven_day_token_data[:tokens]
      fallback_stats = compute_fallback_stats(seven_day_runs)

      status_rate_limits = status_based_rate_limit_counts(seven_day_runs)

      all_keys = provider_keys(run_counts, cost_by_provider, tokens_by_provider, fallback_stats, attempt_metrics, status_rate_limits)
      all_keys.index_with do |key|
        attempt_stats = attempt_metrics.fetch(key, {})
        attempts = attempt_stats.fetch(:attempts, 0)
        successes = attempt_stats.fetch(:successes, 0)

        # Use the higher of attempt-level and status-based rate-limit counts so
        # runs marked rate_limited without providers_attempted data (e.g. via
        # AgentRun#rate_limit!) are not silently undercounted.
        attempt_rate_limits = attempt_stats.fetch(:rate_limits, 0)
        status_rate_limits_count = status_rate_limits.fetch(key) { 0 }
        rate_limits = [ attempt_rate_limits, status_rate_limits_count ].max

        {
          runs_7d: run_counts.fetch(key) { 0 },
          cost_cents_7d: cost_by_provider.fetch(key) { 0 },
          tokens_7d: tokens_by_provider.fetch(key) { 0 },
          attempts_7d: attempts,
          success_attempts_7d: successes,
          success_rate_7d: attempts.zero? ? 0.0 : (successes.to_f / attempts * 100).round(1),
          timeout_events_7d: attempt_stats.fetch(:timeouts, 0),
          fallback_rate: fallback_stats.dig(key, :rate) || 0.0,
          fallback_total: fallback_stats.dig(key, :total) || 0,
          fallback_switched: fallback_stats.dig(key, :switched) || 0,
          rate_limit_events_7d: rate_limits,
          error_events_7d: attempt_stats.fetch(:errors, 0),
          avg_attempt_duration_seconds: attempt_stats.fetch(:avg_duration_seconds, 0.0)
        }
      end
    end

    def provider_keys(*hashes)
      hashes.flat_map(&:keys).uniq
    end

    def account_runs
      AgentRun.joins(:project).where(projects: { account_id: user.account_id })
    end

    def time_filtered_runs(since)
      account_runs.where(created_at: since..)
    end

    def effective_provider_sql
      AgentRun.effective_provider_sql
    end

    def token_data_by_provider(since)
      rows = TokenUsage.billable
        .joins(:agent_run)
        .joins("INNER JOIN projects ON projects.id = agent_runs.project_id")
        .where(projects: { account_id: user.account_id })
        .where(token_usages: { created_at: since.. })
        .group(Arel.sql(effective_provider_sql))
        .pluck(
          Arel.sql(effective_provider_sql),
          Arel.sql("COALESCE(SUM(token_usages.cost_cents), 0)"),
          Arel.sql("COALESCE(SUM(token_usages.input_tokens + token_usages.output_tokens), 0)")
        )

      cost = {}
      tokens = {}
      rows.each do |provider, cost_cents, total_tokens|
        cost[provider] = cost_cents.to_i
        tokens[provider] = total_tokens.to_i
      end

      { cost: cost, tokens: tokens }
    end

    def compute_fallback_stats(runs)
      table = AgentRun.arel_table
      normalized_agent_type = AgentRun.normalized_agent_type_sql

      totals_by_type = runs.group(Arel.sql(normalized_agent_type)).count

      switches = table[:provider_switches].gt(0)
      provider_changed = table[:final_provider].not_eq(nil)
        .and(table[:final_provider].not_eq(""))
        .and(
          Arel.sql(AgentRun.normalize_provider_sql("final_provider"))
            .not_eq(Arel.sql(normalized_agent_type))
        )

      switched_by_type = runs
        .where(switches.or(provider_changed))
        .group(Arel.sql(normalized_agent_type))
        .count

      totals_by_type.each_with_object({}) do |(provider, total), result|
        switched = switched_by_type.fetch(provider) { 0 }
        result[provider] = {
          total: total,
          switched: switched,
          rate: total.zero? ? 0.0 : (switched.to_f / total * 100).round(1)
        }
      end
    end

    def status_based_rate_limit_counts(runs)
      runs.where(status: "rate_limited")
        .group(Arel.sql(effective_provider_sql))
        .count
    end

    def provider_attempt_metrics(since)
      normalized_attempt_provider_sql = AgentRun.normalize_provider_sql("attempt->>'provider'")

      sql = <<~SQL.squish
        SELECT #{normalized_attempt_provider_sql} AS provider,
               COUNT(*)::integer AS attempts,
               COUNT(*) FILTER (WHERE COALESCE((attempt->>'success')::boolean, false))::integer AS successes,
               COUNT(*) FILTER (WHERE attempt->>'error_type' = 'timeout')::integer AS timeouts,
               COUNT(*) FILTER (WHERE attempt->>'error_type' = 'rate_limited')::integer AS rate_limits,
               COUNT(*) FILTER (WHERE attempt->>'error_type' = 'error')::integer AS errors,
               COALESCE(ROUND(AVG(NULLIF(attempt->>'duration_seconds', '')::numeric), 1), 0)::float AS avg_duration_seconds
        FROM agent_runs
        INNER JOIN projects ON projects.id = agent_runs.project_id
        CROSS JOIN LATERAL jsonb_array_elements(COALESCE(agent_runs.providers_attempted, '[]'::jsonb)) AS attempt
        WHERE projects.account_id = #{ActiveRecord::Base.connection.quote(user.account_id)}
          AND agent_runs.created_at >= #{ActiveRecord::Base.connection.quote(since)}
        GROUP BY #{normalized_attempt_provider_sql}
      SQL

      ActiveRecord::Base.connection.select_all(sql).each_with_object({}) do |row, metrics|
        metrics[row.fetch("provider")] = {
          attempts: row.fetch("attempts", 0).to_i,
          successes: row.fetch("successes", 0).to_i,
          timeouts: row.fetch("timeouts", 0).to_i,
          rate_limits: row.fetch("rate_limits", 0).to_i,
          errors: row.fetch("errors", 0).to_i,
          avg_duration_seconds: row.fetch("avg_duration_seconds", 0).to_f
        }
      end
    end
  end
end
