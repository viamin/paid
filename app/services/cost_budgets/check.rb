# frozen_string_literal: true

module CostBudgets
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

      exceeded = project.cost_budgets.exceeded.first
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
