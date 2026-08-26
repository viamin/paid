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
        cost_by_tier: cost_by_tier,
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
      infra_today = infrastructure_cost_cents(starts_at: today_start, ends_at: now)
      infra_month = infrastructure_cost_cents(starts_at: month_start, ends_at: now)
      infra_total = infrastructure_total_cost_cents

      completed = project.agent_runs.where(status: "completed")
      run_count = completed.count
      avg_cost = run_count.zero? ? 0 : (completed.sum(:cost_cents).to_f / run_count).round

      {
        total_cost_cents: project.total_cost_cents,
        infrastructure_cost_cents: infra_total,
        total_variable_cost_cents: project.total_cost_cents + infra_total,
        total_tokens: project.total_tokens_used,
        cost_today_cents: billable_scope.by_time_period(today_start, now).total_cost_cents,
        infrastructure_cost_today_cents: infra_today,
        total_variable_cost_today_cents: billable_scope.by_time_period(today_start, now).total_cost_cents + infra_today,
        cost_this_month_cents: billable_scope.by_time_period(month_start, now).total_cost_cents,
        infrastructure_cost_this_month_cents: infra_month,
        total_variable_cost_this_month_cents: billable_scope.by_time_period(month_start, now).total_cost_cents + infra_month,
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

    def cost_by_tier
      finished_runs = project.agent_runs.finished
        .joins(:model_selection)
        .where.not(model_selections: { tier: nil })

      rows = finished_runs
        .group("model_selections.tier")
        .pluck(
          Arel.sql("model_selections.tier"),
          Arel.sql("COUNT(*)"),
          Arel.sql("COALESCE(SUM(agent_runs.cost_cents), 0)"),
          Arel.sql("AVG(agent_runs.duration_seconds)")
        )

      agg = rows.to_h do |tier, count, cost, avg_dur|
        count = count.to_i
        [ tier, {
          run_count: count,
          total_cost_cents: cost.to_i,
          avg_cost_cents: count.zero? ? 0 : (cost.to_f / count).round,
          avg_duration_seconds: avg_dur&.to_i || 0
        } ]
      end

      LlmModel::TIERS.index_with { |tier| agg[tier] || { run_count: 0, total_cost_cents: 0, avg_cost_cents: 0, avg_duration_seconds: 0 } }
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

    def infrastructure_cost_cents(starts_at:, ends_at:)
      historical_infrastructure_cost_cents(starts_at:, ends_at:) +
        pending_infrastructure_cost_cents(starts_at:, ends_at:)
    end

    def infrastructure_total_cost_cents
      infrastructure_cost_cents(starts_at: Time.at(0), ends_at: Time.current)
    end

    def historical_infrastructure_cost_cents(starts_at:, ends_at:)
      TenantContext.with_system_access do
        ExecutionUsage
          .joins(agent_run: :project)
          .where(projects: { id: project.id })
          .where("execution_usages.provisioned_at < ?", ends_at)
          .where("execution_usages.terminated_at >= ?", starts_at)
          .sum(Arel.sql(execution_usage_overlap_cost_sql(starts_at:, ends_at:)))
          .to_i
      end
    end

    def pending_infrastructure_cost_cents(starts_at:, ends_at:)
      TenantContext.with_system_access do
        AgentRun
          .joins(:project)
          .where(projects: { id: project.id })
          .where.missing(:execution_usage)
          .where.not(provisioning_started_at: nil)
          .where("agent_runs.provisioning_started_at < ?", ends_at)
          .where("agent_runs.completed_at IS NULL OR agent_runs.completed_at >= ?", starts_at)
          .where("agent_runs.completed_at IS NOT NULL OR agent_runs.status IN (?)", AgentRun::ACTIVE_STATUSES)
          .sum(Arel.sql(agent_run_overlap_cost_sql(starts_at:, ends_at:)))
          .to_i
      end
    end

    def execution_usage_overlap_cost_sql(starts_at:, ends_at:)
      <<~SQL.squish
        ROUND(
          (
            execution_usages.rate_cents_per_hour *
            GREATEST(
              EXTRACT(EPOCH FROM (
                LEAST(execution_usages.terminated_at, #{quote_time(ends_at)}) -
                GREATEST(execution_usages.provisioned_at, #{quote_time(starts_at)})
              )),
              0
            )
          ) / 3600.0
        )
      SQL
    end

    def agent_run_overlap_cost_sql(starts_at:, ends_at:)
      <<~SQL.squish
        ROUND(
          (
            COALESCE(
              NULLIF(agent_runs.external_metadata #>> '{infrastructure_spend,rate_cents_per_hour}', ''),
              '0'
            )::numeric *
            GREATEST(
              EXTRACT(EPOCH FROM (
                LEAST(COALESCE(agent_runs.completed_at, #{quote_time(ends_at)}), #{quote_time(ends_at)}) -
                GREATEST(agent_runs.provisioning_started_at, #{quote_time(starts_at)})
              )),
              0
            )
          ) / 3600.0
        )
      SQL
    end

    def quote_time(time)
      ActiveRecord::Base.connection.quote(time)
    end
  end
end
