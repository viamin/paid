# frozen_string_literal: true

module Interop
  class CompareOutcomes
    COMPARISON_METRICS = %w[success_rate avg_duration_seconds avg_tokens_used avg_cost_cents pr_merge_rate].freeze

    ComparisonResult = Struct.new(
      :project_id,
      :period_start,
      :period_end,
      :paid_native,
      :external,
      :by_source,
      keyword_init: true
    )

    MetricSlice = Struct.new(
      :run_count,
      :success_rate,
      :avg_duration_seconds,
      :avg_tokens_used,
      :avg_cost_cents,
      :pr_merge_rate,
      keyword_init: true
    )

    def self.call(...)
      new(...).call
    end

    def initialize(project:, period_start: nil, period_end: nil)
      @project = project
      @period_start = period_start || 30.days.ago
      @period_end = period_end || Time.current
    end

    def call
      ComparisonResult.new(
        project_id: project.id,
        period_start: period_start,
        period_end: period_end,
        paid_native: compute_metrics(paid_native_runs),
        external: compute_metrics(external_runs),
        by_source: compute_by_source_metrics
      )
    end

    private

    attr_reader :project, :period_start, :period_end

    def base_runs
      project.agent_runs
        .where(created_at: period_start..period_end)
        .where(status: AgentRun::FINISHED_STATUSES)
    end

    def paid_native_runs
      base_runs.paid_native
    end

    def external_runs
      base_runs.external_execution
    end

    def compute_metrics(runs)
      runs = runs.to_a
      return empty_metrics if runs.empty?

      completed = runs.select { |r| r.status == "completed" }
      merged = runs.count { |r| r.pull_request_url.present? && r.status == "completed" }

      MetricSlice.new(
        run_count: runs.size,
        success_rate: runs.empty? ? 0.0 : (completed.size.to_f / runs.size).round(4),
        avg_duration_seconds: average_for(runs, :duration_seconds),
        avg_tokens_used: average_tokens(runs),
        avg_cost_cents: average_for(runs, :cost_cents),
        pr_merge_rate: completed.empty? ? 0.0 : (merged.to_f / completed.size).round(4)
      )
    end

    def compute_by_source_metrics
      external_runs
        .to_a
        .group_by(&:external_source_key)
        .transform_values { |runs| compute_metrics(runs) }
    end

    def average_for(runs, field)
      values = runs.map(&field).compact
      return 0.0 if values.empty?

      (values.sum.to_f / values.size).round(2)
    end

    def average_tokens(runs)
      input_values = runs.map(&:tokens_input).compact
      output_values = runs.map(&:tokens_output).compact
      return 0.0 if input_values.empty? && output_values.empty?

      input_avg = input_values.empty? ? 0.0 : (input_values.sum.to_f / input_values.size)
      output_avg = output_values.empty? ? 0.0 : (output_values.sum.to_f / output_values.size)

      (input_avg + output_avg).round(2)
    end

    def empty_metrics
      MetricSlice.new(
        run_count: 0,
        success_rate: 0.0,
        avg_duration_seconds: 0.0,
        avg_tokens_used: 0.0,
        avg_cost_cents: 0.0,
        pr_merge_rate: 0.0
      )
    end
  end
end
