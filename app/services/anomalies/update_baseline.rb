# frozen_string_literal: true

module Anomalies
  class UpdateBaseline
    # Minimum completed runs required before baselines are meaningful.
    MIN_SAMPLE_SIZE = 5

    # Only consider runs from the last 90 days to keep baselines current.
    LOOKBACK_WINDOW = 90.days

    attr_reader :project, :exclude_run

    def initialize(project, exclude_run: nil)
      @project = project
      @exclude_run = exclude_run
    end

    def self.call(project, exclude_run: nil)
      new(project, exclude_run: exclude_run).call
    end

    def call
      runs = completed_runs
      return if runs.count < MIN_SAMPLE_SIZE

      ProjectBaseline::METRIC_NAMES.each do |metric_name|
        values = extract_values(runs, metric_name)
        next if values.size < MIN_SAMPLE_SIZE

        update_baseline(metric_name, values)
      end
    end

    private

    def completed_runs
      scope = project.agent_runs
        .where(status: "completed")
        .where(completed_at: LOOKBACK_WINDOW.ago..)
      scope = scope.where.not(id: exclude_run.id) if exclude_run
      scope
    end

    def extract_values(runs, metric_name)
      case metric_name
      when "tokens_total"
        runs
          .where.not(tokens_input: nil, tokens_output: nil)
          .pluck(:tokens_input, :tokens_output)
          .map { |tokens_input, tokens_output| (tokens_input || 0) + (tokens_output || 0) }
      when "duration_seconds"
        runs.where.not(duration_seconds: nil).pluck(:duration_seconds)
      when "iterations"
        runs.where.not(iterations: nil).pluck(:iterations)
      when "cost_cents"
        runs.where.not(cost_cents: nil).pluck(:cost_cents)
      else
        []
      end.map(&:to_f)
    end

    def update_baseline(metric_name, values)
      mean = values.sum / values.size
      variance = values.sum { |v| (v - mean)**2 } / values.size
      std_dev = Math.sqrt(variance)
      p95 = percentile(values, 95)

      attrs = {
        mean: mean,
        standard_deviation: std_dev,
        sample_count: values.size,
        p95: p95,
        last_calculated_at: Time.current
      }

      retries = 0
      begin
        baseline = project.project_baselines.find_or_initialize_by(metric_name: metric_name)
        baseline.update!(attrs)
      rescue ActiveRecord::RecordNotUnique
        retries += 1
        raise if retries > 1

        baseline = project.project_baselines.find_by!(metric_name: metric_name)
        retry
      end
    end

    def percentile(values, pct)
      sorted = values.sort
      k = (pct / 100.0 * (sorted.size - 1))
      floor = k.floor
      ceil = k.ceil
      return sorted[floor] if floor == ceil

      sorted[floor] + (k - floor) * (sorted[ceil] - sorted[floor])
    end
  end
end
