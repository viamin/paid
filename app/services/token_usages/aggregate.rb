# frozen_string_literal: true

module TokenUsages
  class Aggregate
    attr_reader :scope

    # Defaults to billable scope (excludes run_summary records) to avoid
    # double-counting when both per-request proxy tracking and run-level
    # summaries exist. Pass scope: TokenUsage.all to include everything.
    def initialize(scope: TokenUsage.billable)
      @scope = scope
    end

    def self.call(...)
      new(...).call
    end

    def self.for_project(project_id)
      new(scope: TokenUsage.billable.by_project(project_id)).call
    end

    def call
      {
        total_cost_cents: scope.total_cost_cents,
        total_input_tokens: scope.total_input_tokens,
        total_output_tokens: scope.total_output_tokens,
        cost_by_model: scope.cost_by_model,
        cost_by_request_type: scope.cost_by_request_type
      }
    end

    def daily_breakdown(days: 30)
      scope.daily_costs(days: days)
    end

    def project_cost_projection(days_ahead: 30)
      recent_costs = scope.by_time_period(30.days.ago, Time.current)
      daily_average = calculate_daily_average(recent_costs)

      {
        daily_average_cents: daily_average,
        projected_cost_cents: (daily_average * days_ahead).round
      }
    end

    private

    def calculate_daily_average(recent_scope)
      total = recent_scope.total_cost_cents
      return 0 if total.zero?

      days = [ (Time.current.to_date - 30.days.ago.to_date).to_i, 1 ].max
      (total.to_f / days).round
    end
  end
end
