# frozen_string_literal: true

module ScalingExperiments
  module Statistics
    extend self

    Z_SCORES = {
      0.80 => 1.2816,
      0.90 => 1.6449,
      0.95 => 1.96,
      0.99 => 2.5758
    }.freeze

    def mean_interval(values:, confidence_level:)
      samples = Array(values).filter_map do |value|
        numeric = Float(value)
        numeric.finite? ? numeric : nil
      rescue ArgumentError, TypeError
        nil
      end
      return empty_interval(confidence_level:) if samples.empty?

      mean = samples.sum / samples.size
      return point_interval(mean:, confidence_level:) if samples.one?

      variance = samples.sum { |value| (value - mean) ** 2 } / (samples.size - 1)
      standard_error = Math.sqrt(variance) / Math.sqrt(samples.size)
      margin = z_score_for(confidence_level) * standard_error

      build_interval(
        mean:,
        lower_bound: mean - margin,
        upper_bound: mean + margin,
        margin_of_error: margin,
        sample_count: samples.size,
        confidence_level:
      )
    end

    def proportion_interval(successes:, trials:, confidence_level:)
      total = trials.to_i
      return empty_interval(confidence_level:) if total <= 0

      hits = successes.to_f.clamp(0.0, total.to_f)
      z_score = z_score_for(confidence_level)
      p_hat = hits / total
      denominator = 1 + ((z_score**2) / total)
      center = (p_hat + ((z_score**2) / (2 * total))) / denominator
      adjusted_margin = (z_score * Math.sqrt((p_hat * (1 - p_hat) / total) + ((z_score**2) / (4 * (total**2))))) / denominator

      build_interval(
        mean: p_hat,
        lower_bound: center - adjusted_margin,
        upper_bound: center + adjusted_margin,
        margin_of_error: adjusted_margin,
        sample_count: total,
        confidence_level:
      )
    end

    def log_log_slope_interval(points:, confidence_level:)
      normalized = Array(points).filter_map do |point|
        x = Float(point.fetch(:x))
        y = Float(point.fetch(:y))
        next unless x.positive? && y.positive?

        { x: Math.log(x), y: Math.log(y) }
      rescue ArgumentError, TypeError, KeyError
        nil
      end
      return empty_regression_interval(confidence_level:) if normalized.size < 2

      x_mean = normalized.sum { |point| point[:x] } / normalized.size
      y_mean = normalized.sum { |point| point[:y] } / normalized.size
      ss_xx = normalized.sum { |point| (point[:x] - x_mean) ** 2 }
      return empty_regression_interval(confidence_level:) if ss_xx.zero?

      ss_xy = normalized.sum { |point| (point[:x] - x_mean) * (point[:y] - y_mean) }
      slope = ss_xy / ss_xx
      return point_regression_interval(slope:, sample_count: normalized.size, confidence_level:) if normalized.size < 3

      intercept = y_mean - (slope * x_mean)
      residual_sum_squares = normalized.sum do |point|
        fitted = intercept + (slope * point[:x])
        (point[:y] - fitted) ** 2
      end
      standard_error = Math.sqrt((residual_sum_squares / (normalized.size - 2)) / ss_xx)
      margin = z_score_for(confidence_level) * standard_error

      {
        "estimate" => slope.round(4),
        "lower_bound" => (slope - margin).round(4),
        "upper_bound" => (slope + margin).round(4),
        "margin_of_error" => margin.round(4),
        "sample_count" => normalized.size,
        "confidence_level" => confidence_level.round(2)
      }
    end

    def relative_width(interval, baseline: nil)
      lower_bound = interval&.fetch("lower_bound", nil)
      upper_bound = interval&.fetch("upper_bound", nil)
      return nil unless lower_bound && upper_bound

      denominator = baseline.to_f
      denominator = interval.fetch("mean", 0).to_f if denominator.zero?
      return nil if denominator.zero?

      ((upper_bound - lower_bound).abs / denominator.abs).round(4)
    end

    private

    def z_score_for(confidence_level)
      normalized = confidence_level.to_f.round(2)
      Z_SCORES.fetch(normalized, Z_SCORES.fetch(0.95))
    end

    def empty_interval(confidence_level:)
      {
        "mean" => nil,
        "lower_bound" => nil,
        "upper_bound" => nil,
        "margin_of_error" => nil,
        "sample_count" => 0,
        "confidence_level" => confidence_level.round(2)
      }
    end

    def point_interval(mean:, confidence_level:)
      build_interval(
        mean:,
        lower_bound: mean,
        upper_bound: mean,
        margin_of_error: 0.0,
        sample_count: 1,
        confidence_level:
      )
    end

    def build_interval(mean:, lower_bound:, upper_bound:, margin_of_error:, sample_count:, confidence_level:)
      {
        "mean" => mean.round(4),
        "lower_bound" => lower_bound.round(4),
        "upper_bound" => upper_bound.round(4),
        "margin_of_error" => margin_of_error.round(4),
        "sample_count" => sample_count,
        "confidence_level" => confidence_level.round(2)
      }
    end

    def empty_regression_interval(confidence_level:)
      {
        "estimate" => nil,
        "lower_bound" => nil,
        "upper_bound" => nil,
        "margin_of_error" => nil,
        "sample_count" => 0,
        "confidence_level" => confidence_level.round(2)
      }
    end

    def point_regression_interval(slope:, sample_count:, confidence_level:)
      {
        "estimate" => slope.round(4),
        "lower_bound" => slope.round(4),
        "upper_bound" => slope.round(4),
        "margin_of_error" => 0.0,
        "sample_count" => sample_count,
        "confidence_level" => confidence_level.round(2)
      }
    end
  end
end
