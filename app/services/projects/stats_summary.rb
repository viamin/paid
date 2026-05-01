# frozen_string_literal: true

module Projects
  class StatsSummary
    attr_reader :project, :now

    TODAY_CACHE_TTL = 5.minutes
    MONTH_CACHE_TTL = 15.minutes

    def initialize(project:, budgets: project.cost_budgets.load, now: Time.current, skip_cache: false)
      @project = project
      @budgets = Array(budgets)
      @now = now
      @skip_cache = skip_cache
    end

    def self.call(...)
      new(...).call
    end

    def call
      {
        today_cost_cents: period_cost_cents("daily", now.beginning_of_day, TODAY_CACHE_TTL),
        monthly_cost_cents: period_cost_cents("monthly", now.beginning_of_month, MONTH_CACHE_TTL)
      }
    end

    private

    attr_reader :budgets

    def period_cost_cents(budget_type, period_start, ttl)
      budget = budgets.find { |item| item.budget_type == budget_type }
      if budget && active_period?(budget, period_start)
        return budget.current_usage_cents + chat_session_cost_cents(period_start)
      end

      compute_and_cache(period_cache_key(budget_type, period_start), ttl) do
        period_cost_from_sources(period_start)
      end
    end

    def active_period?(budget, period_start)
      budget.period_started_at.present? && budget.period_started_at >= period_start
    end

    def compute_and_cache(key, ttl, &block)
      return block.call if @skip_cache

      Rails.cache.fetch(key, expires_in: ttl, &block)
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
      agent_run_cost_cents(period_start) +
        knowledge_run_cost_cents(period_start) +
        chat_session_cost_cents(period_start)
    end

    def agent_run_cost_cents(period_start)
      TokenUsage.billable
        .where(agent_run_id: project.agent_runs.select(:id))
        .by_time_period(period_start, now)
        .total_cost_cents
    end

    def knowledge_run_cost_cents(period_start)
      TokenUsage.billable
        .where(knowledge_run_id: project.knowledge_runs.select(:id))
        .by_time_period(period_start, now)
        .total_cost_cents
    end

    def chat_session_cost_cents(period_start)
      TokenUsage.billable
        .where(chat_session_id: ChatSession.where(project_id: project.id).select(:id))
        .by_time_period(period_start, now)
        .total_cost_cents
    end
  end
end
