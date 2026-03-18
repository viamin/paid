# frozen_string_literal: true

module CostBudgets
  # Checks whether a project's cost budgets allow a new agent run.
  # Intended to be called as a pre-flight check before transitioning
  # an AgentRun to "running" (e.g., in the run queue processor or
  # workflow start path). This service provides the enforcement logic;
  # wiring into ProcessRunQueueJob is tracked in a follow-up issue
  # and intentionally deferred from this PR to keep scope limited
  # to the model/infrastructure layer. See issue #141.
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
      return allowed_result if project.cost_budgets.none?

      rollover_expired_periods

      # Priority: per_run > daily > monthly (most specific first).
      # Check per_run budgets first against this specific agent_run's usage,
      # avoiding the race condition where concurrent runs share a counter.
      if agent_run
        reset_per_run_budgets
        per_run_exceeded = check_per_run_budget
        return blocked_result(per_run_exceeded) if per_run_exceeded
      end

      # Check daily/monthly budgets via the shared counter
      exceeded = project.cost_budgets.where(budget_type: %w[daily monthly]).reload.exceeded
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

    def blocked_result(budget)
      {
        allowed: false,
        reason: "#{budget.budget_type} budget exceeded (#{budget.usage_percent}% of #{budget.limit_cents} cents used)"
      }
    end

    # Checks per_run budgets by computing usage from the agent_run's own
    # token_usages rather than a shared counter. This is safe for concurrent
    # runs because each run's usage is isolated by agent_run_id.
    def check_per_run_budget
      project.cost_budgets.per_run.find do |budget|
        run_cost = agent_run.token_usages.sum(:cost_cents)
        run_cost >= budget.limit_cents
      end
    end

    def reset_per_run_budgets
      project.cost_budgets.per_run.find_each(&:reset_for_new_run!)
    end

    def rollover_expired_periods
      project.cost_budgets.where(budget_type: %w[daily monthly]).find_each(&:rollover_if_period_expired!)
    end

    def send_alerts_if_needed
      project.cost_budgets.each do |budget|
        next unless budget.alert_needed?

        Rails.logger.warn(
          message: "cost_budget.threshold_reached",
          project_id: project.id,
          budget_type: budget.budget_type,
          usage_percent: budget.usage_percent,
          current_usage_cents: budget.current_usage_cents,
          limit_cents: budget.limit_cents
        )

        budget.mark_alert_sent!
      end
    end
  end
end
