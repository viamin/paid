# frozen_string_literal: true

module CostBudgets
  # Budget enforcement service for agent runs. Performs two kinds of checks:
  #
  # 1. **Daily/monthly** — pre-flight checks using the shared `current_usage_cents`
  #    counter. These can block a run *before* it starts.
  # 2. **Per-run** — in-run checks using `agent_run.token_usages.sum(:cost_cents)`,
  #    which is only meaningful *after* usage has accrued. These detect a single
  #    run exceeding its per-run budget and should be called periodically during
  #    execution (not solely at start).
  #
  # Only budgets with `enforcement_mode: "hard_stop"` will block runs.
  # Budgets in "alert" mode log warnings but never block.
  class Check
    # Explicit priority for which exceeded budget blocks a run first.
    # per_run is most specific, then daily, then monthly.
    BUDGET_TYPE_PRIORITY = %w[per_run daily monthly].freeze

    PRIORITY_ORDER_SQL = "ARRAY_POSITION(ARRAY[#{BUDGET_TYPE_PRIORITY.map { |t| "'#{t}'" }.join(",")}], budget_type)"

    attr_reader :project, :agent_run

    def initialize(project, agent_run: nil)
      @project = project
      @agent_run = agent_run
    end

    def self.call(project, agent_run: nil)
      new(project, agent_run: agent_run).call
    end

    def call
      return allowed_result unless project.cost_budgets.exists?

      rollover_expired_periods

      if agent_run
        per_run_exceeded = check_per_run_budget
        return blocked_result(per_run_exceeded, actual_usage_cents: @per_run_cost) if per_run_exceeded
      end

      # Check daily/monthly hard_stop budgets via the shared counter.
      # Use effective_limit_cents (includes grace buffer) for enforcement.
      exceeded = project.cost_budgets
        .hard_stop
        .where(budget_type: %w[daily monthly])
        .where("current_usage_cents >= (limit_cents * (100 + grace_buffer_percent) / 100.0)")
        .order(Arel.sql(PRIORITY_ORDER_SQL))
        .first
      return blocked_result(exceeded) if exceeded

      send_alerts_if_needed

      allowed_result
    end

    private

    def allowed_result
      { allowed: true }
    end

    def blocked_result(budget, actual_usage_cents: nil)
      usage = actual_usage_cents || budget.current_usage_cents
      effective_limit = budget.effective_limit_cents
      percent = effective_limit.positive? ? (usage.to_f / effective_limit * 100).round(1) : 0
      {
        allowed: false,
        reason: "#{budget.budget_type} budget exceeded: #{usage} of #{budget.limit_cents} cents used (#{percent}%)",
        budget: budget
      }
    end

    # Checks per_run budgets by computing billable usage from the agent_run's
    # own token_usages rather than a shared counter. Only hard_stop budgets
    # block runs; alert-mode budgets are skipped.
    def check_per_run_budget
      hard_stop_budgets = project.cost_budgets.per_run.hard_stop.to_a
      return nil if hard_stop_budgets.empty?

      run_cost = agent_run.token_usages.where.not(request_type: "run_summary").sum(:cost_cents)
      exceeded_budget = hard_stop_budgets.find { |budget| run_cost >= budget.effective_limit_cents }
      return nil unless exceeded_budget

      @per_run_cost = run_cost
      exceeded_budget
    end

    def rollover_expired_periods
      project.cost_budgets.where(budget_type: %w[daily monthly]).find_each(&:rollover_if_period_expired!)
    end

    def send_alerts_if_needed
      project.cost_budgets.each do |budget|
        # Always skip per_run budgets — their current_usage_cents is not
        # maintained by TokenUsageTracker (per_run enforcement uses
        # agent_run.token_usages.sum(:cost_cents) instead), so alert_needed?
        # would always check against stale/zero values.
        next if budget.budget_type == "per_run"
        next unless budget.alert_needed?

        Rails.logger.warn(
          message: "cost_budget.threshold_reached",
          project_id: project.id,
          budget_type: budget.budget_type,
          usage_percent: budget.usage_percent,
          current_usage_cents: budget.current_usage_cents,
          limit_cents: budget.limit_cents,
          enforcement_mode: budget.enforcement_mode
        )

        budget.mark_alert_sent!
      end
    end
  end
end
