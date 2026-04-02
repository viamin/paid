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
        cost_by_outcome: cost_by_outcome,
        cost_by_goal: cost_by_goal,
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

      completed = project.agent_runs.where(status: "completed")
      run_count = completed.count
      avg_cost = run_count.zero? ? 0 : (completed.sum(:cost_cents).to_f / run_count).round

      {
        total_cost_cents: project.total_cost_cents,
        total_tokens: project.total_tokens_used,
        cost_today_cents: billable_scope.by_time_period(today_start, now).total_cost_cents,
        cost_this_month_cents: billable_scope.by_time_period(month_start, now).total_cost_cents,
        avg_cost_per_run_cents: avg_cost,
        total_runs: run_count
      }
    end

    def cost_by_outcome
      finished_runs = project.agent_runs.finished
      outcome_sql = Arel.sql(<<~SQL.squish)
        CASE WHEN status = 'completed' THEN 'completed' ELSE 'other' END
      SQL

      rows = finished_runs
        .group(outcome_sql)
        .pluck(
          outcome_sql,
          Arel.sql("COUNT(*)"),
          Arel.sql("COALESCE(SUM(cost_cents), 0)"),
          Arel.sql("COALESCE(SUM(COALESCE(tokens_input, 0) + COALESCE(tokens_output, 0)), 0)"),
          Arel.sql("AVG(duration_seconds)")
        )

      result = %w[completed other].index_with { |_| empty_cost_summary }
      rows.each do |outcome, count, cost, tokens, avg_dur|
        count = count.to_i
        result[outcome] = {
          run_count: count,
          total_cost_cents: cost.to_i,
          avg_cost_cents: count.zero? ? 0 : (cost.to_f / count).round,
          total_tokens: tokens.to_i,
          avg_duration_seconds: avg_dur&.to_i || 0
        }
      end
      result
    end

    def cost_by_goal
      finished_runs = project.agent_runs.finished
      rows = finished_runs
        .group(:goal)
        .pluck(
          :goal,
          Arel.sql("COUNT(*)"),
          Arel.sql("COALESCE(SUM(cost_cents), 0)"),
          Arel.sql("COALESCE(SUM(COALESCE(tokens_input, 0) + COALESCE(tokens_output, 0)), 0)"),
          Arel.sql("AVG(duration_seconds)")
        )

      agg = rows.to_h do |goal, count, cost, tokens, avg_dur|
        count = count.to_i
        [ goal, {
          run_count: count,
          total_cost_cents: cost.to_i,
          avg_cost_cents: count.zero? ? 0 : (cost.to_f / count).round,
          total_tokens: tokens.to_i,
          avg_duration_seconds: avg_dur&.to_i || 0
        } ]
      end

      AgentRun::GOALS.index_with { |goal| agg[goal] || empty_cost_summary }
    end

    def empty_cost_summary
      { run_count: 0, total_cost_cents: 0, avg_cost_cents: 0, total_tokens: 0, avg_duration_seconds: 0 }
    end

    def cost_by_model
      billable_scope.cost_by_model.sort_by { |_, v| -v }
    end

    def cost_by_request_type
      billable_scope.cost_by_request_type.sort_by { |_, v| -v }
    end

    def daily_costs
      raw_costs = billable_scope.daily_costs(days: 30)
      today = Time.current.to_date
      start_date = today - 29

      (start_date..today).map do |date|
        [ date, raw_costs[date] || 0 ]
      end
    end

    def budgets
      project.cost_budgets.order(:budget_type).map do |budget|
        base_stats = {
          id: budget.id,
          budget_type: budget.budget_type,
          limit_cents: budget.limit_cents,
          exceeded: budget.exceeded?,
          alert_threshold_percent: budget.alert_threshold_percent,
          enforcement_mode: budget.enforcement_mode,
          grace_buffer_percent: budget.grace_buffer_percent,
          hard_stop_exceeded: budget.hard_stop? && budget.hard_stop_exceeded?
        }

        # Per-run budgets are enforced per agent run via
        # agent_run.token_usages.sum(:cost_cents) in CostBudgets::Check,
        # not via current_usage_cents. Omit period-based usage fields to
        # avoid showing misleading "0% used" stats.
        if budget.budget_type == "per_run"
          base_stats
        else
          base_stats.merge(
            current_usage_cents: budget.current_usage_cents,
            usage_percent: budget.usage_percent,
            remaining_cents: budget.remaining_cents
          )
        end
      end
    end
  end
end
