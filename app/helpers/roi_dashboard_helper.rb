# frozen_string_literal: true

module RoiDashboardHelper
  INVERSE_ROI_METRICS = %i[average_cycle_time_hours rework_rate defect_escape_rate cost_per_accepted_pr_cents].freeze

  def roi_metric_value(metric_key, value)
    return "--" if value.nil?

    case metric_key.to_sym
    when :merge_rate, :rework_rate, :defect_escape_rate
      number_to_percentage(value, precision: 1)
    when :average_cycle_time_hours
      "#{value.round(1)}h"
    when :cost_per_accepted_pr_cents
      format_cost_cents(value.to_i)
    else
      value
    end
  end

  def roi_delta(metric_key, current, baseline)
    return "--" if current.nil? || baseline.nil?

    delta = current - baseline
    if metric_key.to_sym == :cost_per_accepted_pr_cents
      cents = delta.round
      sign = cents.positive? ? "+" : cents.negative? ? "-" : ""
      "#{sign}#{format_cost_cents(cents.abs)}"
    elsif metric_key.to_sym == :average_cycle_time_hours
      sign = delta.positive? ? "+" : ""
      "#{sign}#{delta.round(1)}h"
    else
      sign = delta.positive? ? "+" : ""
      "#{sign}#{number_to_percentage(delta, precision: 1)}"
    end
  end

  def roi_delta_class(metric_key, current, baseline)
    return "text-gray-400" if current.nil? || baseline.nil?

    delta = current - baseline
    favorable = INVERSE_ROI_METRICS.include?(metric_key.to_sym) ? delta.negative? : delta.positive?

    if favorable
      "text-green-600"
    elsif delta.zero?
      "text-gray-500"
    else
      "text-red-600"
    end
  end

  def roi_benchmark_type_label(benchmark_type)
    case benchmark_type
    when "human_only"
      "Human-only"
    when "commercial_agent"
      "Commercial agent"
    else
      benchmark_type.to_s.titleize
    end
  end
end
