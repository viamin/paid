# frozen_string_literal: true

module Projects
  class CostDashboardStats
    attr_reader :project

    def initialize(project:)
      @project = project
    end

    def self.call(...)
      new(...).call
    end

    def call
      {
        summary: summary,
        cost_by_model: cost_by_model,
        cost_by_request_type: cost_by_request_type,
        daily_costs: daily_costs,
        budgets: budgets
      }
    end

    private

    def billable_scope
      @billable_scope ||= TokenUsage.billable.by_project(project.id)
    end

    def summary
      now = Time.current
      today_start = now.beginning_of_day
      month_start = now.beginning_of_month

      {
        total_cost_cents: project.total_cost_cents,
        total_tokens: project.total_tokens_used,
        cost_today_cents: billable_scope.by_time_period(today_start, now).total_cost_cents,
        cost_this_month_cents: billable_scope.by_time_period(month_start, now).total_cost_cents,
        avg_cost_per_run_cents: avg_cost_per_run_cents,
        total_runs: project.agent_runs.count
      }
    end

    def avg_cost_per_run_cents
      completed = project.agent_runs.where(status: "completed")
      count = completed.count
      return 0 if count.zero?

      total = completed.sum(:cost_cents)
      (total.to_f / count).round
    end

    def cost_by_model
      billable_scope.cost_by_model.sort_by { |_, v| -v }
    end

    def cost_by_request_type
      billable_scope.cost_by_request_type.sort_by { |_, v| -v }
    end

    def daily_costs
      billable_scope.daily_costs(days: 30).sort_by { |date, _| date }
    end

    def budgets
      project.cost_budgets.order(:budget_type).map do |budget|
        {
          id: budget.id,
          budget_type: budget.budget_type,
          limit_cents: budget.limit_cents,
          current_usage_cents: budget.current_usage_cents,
          usage_percent: budget.usage_percent,
          remaining_cents: budget.remaining_cents,
          exceeded: budget.exceeded?,
          alert_threshold_percent: budget.alert_threshold_percent
        }
      end
    end
  end
end
