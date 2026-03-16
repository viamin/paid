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
    attr_reader :project

    def initialize(project)
      @project = project
    end

    def self.call(project)
      new(project).call
    end

    def call
      return allowed_result if project.cost_budgets.none?

      reset_per_run_budgets
      rollover_expired_periods

      exceeded = project.cost_budgets.reload.exceeded.order(:budget_type).first
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

    def reset_per_run_budgets
      project.cost_budgets.per_run.each(&:reset_for_new_run!)
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
