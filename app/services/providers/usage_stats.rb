# frozen_string_literal: true

module Providers
  class UsageStats
    CACHE_TTL = 5.minutes

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
      "providers/usage_stats/#{user.id}"
    end

    def build_stats
      seven_day_runs = time_filtered_runs(7.days.ago)
      seven_day_token_data = token_data_by_provider(7.days.ago)

      run_counts = seven_day_runs.group(Arel.sql(effective_provider_sql)).count
      cost_by_provider = seven_day_token_data[:cost]
      tokens_by_provider = seven_day_token_data[:tokens]
      fallback_stats = compute_fallback_stats(seven_day_runs)
      rate_limit_counts = compute_rate_limit_counts(seven_day_runs)

      all_keys = provider_keys(run_counts, cost_by_provider, tokens_by_provider, fallback_stats, rate_limit_counts)
      all_keys.index_with do |key|
        {
          runs_7d: run_counts.fetch(key, 0),
          cost_cents_7d: cost_by_provider.fetch(key, 0),
          tokens_7d: tokens_by_provider.fetch(key, 0),
          fallback_rate: fallback_stats.dig(key, :rate) || 0.0,
          fallback_total: fallback_stats.dig(key, :total) || 0,
          fallback_switched: fallback_stats.dig(key, :switched) || 0,
          rate_limit_events_7d: rate_limit_counts.fetch(key, 0)
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
        switched = switched_by_type.fetch(provider, 0)
        result[provider] = {
          total: total,
          switched: switched,
          rate: total.zero? ? 0.0 : (switched.to_f / total * 100).round(1)
        }
      end
    end

    def compute_rate_limit_counts(runs)
      runs.where(status: "rate_limited")
        .group(Arel.sql(effective_provider_sql))
        .count
    end
  end
end
