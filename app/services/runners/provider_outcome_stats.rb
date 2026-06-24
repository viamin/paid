# frozen_string_literal: true

module Runners
  class ProviderOutcomeStats
    CACHE_TTL = 15.minutes
    TIME_RANGES = %w[cumulative 30d 7d].freeze

    # Finished statuses tracked in the outcomes chart (ordered for display)
    TRACKED_STATUSES = %w[completed no_output failed timeout token_budget_exceeded auth_expired rate_limited cancelled].freeze

    # Colors aligned with the issue spec and application_helper AGENT_RUN_STATUS_STYLES
    STATUS_COLORS = {
      "completed" => "#16a34a",
      "no_output" => "#7c3aed",
      "failed" => "#dc2626",
      "timeout" => "#ea580c",
      "token_budget_exceeded" => "#e11d48",
      "auth_expired" => "#2563eb",
      "rate_limited" => "#ca8a04",
      "cancelled" => "#6b7280"
    }.freeze

    STATUS_LABELS = {
      "completed" => "Completed",
      "no_output" => "No Output",
      "failed" => "Failed",
      "timeout" => "Timeout",
      "token_budget_exceeded" => "Token Budget Exceeded",
      "auth_expired" => "Auth Expired",
      "rate_limited" => "Rate Limited",
      "cancelled" => "Cancelled"
    }.freeze

    attr_reader :account, :time_range

    def initialize(account:, time_range: "30d")
      @account = account
      @time_range = TIME_RANGES.include?(time_range) ? time_range : "30d"
    end

    def self.call(...)
      new(...).call
    end

    def call
      Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) { build_stats }
    end

    private

    def cache_key
      "runners/provider_outcome_stats/#{account.id}/#{time_range}"
    end

    def build_stats
      rows = fetch_daily_counts
      date_range = compute_date_range

      totals_by_provider = Hash.new(0)
      completed_by_provider = Hash.new(0)
      # provider -> date -> status -> count
      nested = {}

      rows.each do |provider, date, status, count|
        n = count.to_i
        nested[provider] ||= {}
        nested[provider][date] ||= {}
        nested[provider][date][status] = n
        totals_by_provider[provider] += n
        completed_by_provider[provider] += n if status == "completed"
      end

      totals_by_provider.sort_by { |_, total| -total }.map do |provider, total|
        completed = completed_by_provider[provider]
        rate = total.zero? ? 0.0 : (completed.to_f / total * 100).round(1)
        dates = date_range || nested.fetch(provider, {}).keys.sort

        {
          provider: provider,
          total_runs: total,
          completed: completed,
          completion_rate: rate,
          colors: TRACKED_STATUSES.map { |s| STATUS_COLORS[s] },
          series: build_series(nested.fetch(provider, {}), dates)
        }
      end
    end

    def fetch_daily_counts
      normalized_type = Arel.sql(AgentRun.normalized_agent_type_sql)

      create_pr_runs
        .group(normalized_type, Arel.sql("DATE(agent_runs.completed_at)"), :status)
        .pluck(
          normalized_type,
          Arel.sql("DATE(agent_runs.completed_at)"),
          :status,
          Arel.sql("COUNT(*)")
        )
    end

    def create_pr_runs
      scope = AgentRun
        .joins(:project)
        .where(projects: { account_id: account.id })
        .where(goal: "create_pr")
        .where(status: TRACKED_STATUSES)
        .where.not(completed_at: nil)

      apply_time_range(scope)
    end

    def apply_time_range(scope)
      return scope if time_range == "cumulative"

      cutoff = time_range == "7d" ? 7.days.ago : 30.days.ago
      scope.where(completed_at: cutoff..)
    end

    def compute_date_range
      return nil if time_range == "cumulative"

      days = time_range == "7d" ? 7 : 30
      start_date = (days - 1).days.ago.to_date
      end_date = Time.zone.today
      (start_date..end_date).to_a
    end

    def build_series(provider_data, dates)
      TRACKED_STATUSES.map do |status|
        {
          name: STATUS_LABELS[status],
          data: dates.index_with { |date| provider_data.dig(date, status) || 0 }
        }
      end
    end
  end
end
