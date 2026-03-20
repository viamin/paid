# frozen_string_literal: true

module TokenUsages
  class Aggregate
    attr_reader :scope

    # Defaults to billable scope which excludes run_summary audit records.
    # Billing uses per-request proxy records and run_delta records (the gap
    # between run totals and proxy totals). run_summary is only included as
    # a legacy fallback when it is the sole record for a run.
    # Pass scope: TokenUsage.all to include everything regardless.
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
      # billable is applied before by_time_period intentionally. The billable
      # scope's subquery must check for proxy records globally (not just within
      # the time window) so that a run_summary is excluded whenever proxy records
      # exist for that run — even if those proxy records fall outside the window.
      # Reversing the order would cause run_summary records to be incorrectly
      # included (double-counted) when their proxy records predate the window.
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
