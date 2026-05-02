# frozen_string_literal: true

module Projects
  class StatsSummary
    attr_reader :project, :now

    TODAY_CACHE_TTL = 5.minutes
    MONTH_CACHE_TTL = 15.minutes

    def initialize(project:, now: Time.current)
      @project = project
      @now = now
    end

    def self.call(...)
      new(...).call
    end

    def self.bust_cache!(project_id)
      now = Time.current
      %w[daily monthly].each do |budget_type|
        period_start = budget_type == "daily" ? now.beginning_of_day : now.beginning_of_month
        key = [ "projects", project_id, "stats_summary", budget_type, period_start.to_date.iso8601 ]
        Rails.cache.delete(key)
      end
    end

    def call
      {
        today_cost_cents: period_cost_cents("daily", now.beginning_of_day, TODAY_CACHE_TTL),
        monthly_cost_cents: period_cost_cents("monthly", now.beginning_of_month, MONTH_CACHE_TTL)
      }
    end

    private

    def period_cost_cents(budget_type, period_start, ttl)
      Rails.cache.fetch(period_cache_key(budget_type, period_start), expires_in: ttl) do
        period_cost_from_sources(period_start)
      end
    end

    def period_cache_key(budget_type, period_start)
      [
        "projects",
        project.id,
        "stats_summary",
        budget_type,
        period_start.to_date.iso8601
      ]
    end

    def period_cost_from_sources(period_start)
      TokenUsage.billable
        .by_project(project.id)
        .by_time_period(period_start, now)
        .total_cost_cents
    end
  end
end
