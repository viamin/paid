# frozen_string_literal: true

module AbTests
  # Analyzes A/B test results using Welch's t-test to determine
  # if any variant is statistically significantly better than control.
  #
  # @example
  #   result = AbTests::Analyze.call(ab_test: test)
  #   result[:status]     # => :winner_found, :control_wins, :no_significant_difference, :insufficient_data
  #   result[:winner]     # => AbTestVariant (if winner_found)
  #   result[:confidence] # => 0.97 (if winner_found)
  class Analyze
    Result = Struct.new(:status, :winner, :confidence, :improvement, :details, keyword_init: true)

    attr_reader :ab_test

    def initialize(ab_test:)
      @ab_test = ab_test
    end

    def self.call(...)
      new(...).analyze
    end

    def analyze
      variants = ab_test.ab_test_variants.includes(:ab_test_assignments).to_a
      control = variants.find(&:is_control)

      return Result.new(status: :insufficient_data) unless control
      return Result.new(status: :insufficient_data) unless all_have_minimum_samples?(variants)

      control_scores = scores_for(control)
      return Result.new(status: :insufficient_data) if control_scores.size < 2

      results = variants.reject(&:is_control).map do |variant|
        variant_scores = scores_for(variant)
        next nil if variant_scores.size < 2

        t_result = welch_t_test(control_scores, variant_scores)
        {
          variant: variant,
          mean_diff: mean(variant_scores) - mean(control_scores),
          p_value: t_result[:p_value],
          significant: t_result[:p_value] < (1 - ab_test.confidence_threshold)
        }
      end.compact

      determine_outcome(results)
    end

    private

    def all_have_minimum_samples?(variants)
      variants.all? { |v| v.sample_count >= ab_test.min_samples_per_variant }
    end

    def scores_for(variant)
      variant.ab_test_assignments.filter_map(&:quality_score).map(&:to_f)
    end

    def determine_outcome(results)
      significant_improvements = results.select { |r| r[:significant] && r[:mean_diff] > 0 }

      if significant_improvements.any?
        winner = significant_improvements.max_by { |r| r[:mean_diff] }
        Result.new(
          status: :winner_found,
          winner: winner[:variant],
          confidence: 1 - winner[:p_value],
          improvement: winner[:mean_diff],
          details: results
        )
      elsif results.all? { |r| r[:significant] && r[:mean_diff] < 0 }
        Result.new(status: :control_wins, details: results)
      else
        Result.new(status: :no_significant_difference, details: results)
      end
    end

    # Welch's t-test for two independent samples with possibly unequal variances.
    def welch_t_test(group1, group2)
      n1 = group1.size
      n2 = group2.size
      m1 = mean(group1)
      m2 = mean(group2)
      s1 = std_dev(group1)
      s2 = std_dev(group2)

      # Avoid division by zero when both groups have zero variance
      se = Math.sqrt((s1**2 / n1) + (s2**2 / n2))
      return { t: 0.0, df: n1 + n2 - 2, p_value: 1.0 } if se.zero?

      t = (m1 - m2) / se

      # Welch-Satterthwaite degrees of freedom
      numerator = ((s1**2 / n1) + (s2**2 / n2))**2
      denominator = ((s1**4 / (n1**2 * (n1 - 1))) + (s2**4 / (n2**2 * (n2 - 1))))
      df = denominator.zero? ? [ n1, n2 ].min - 1 : numerator / denominator

      p_value = two_tailed_p_value(t.abs, [ df.floor, 1 ].max)
      { t: t, df: df, p_value: p_value }
    end

    def mean(values)
      values.sum / values.size.to_f
    end

    def std_dev(values)
      return 0.0 if values.size < 2

      m = mean(values)
      variance = values.sum { |v| (v - m)**2 } / (values.size - 1).to_f
      Math.sqrt(variance)
    end

    # Approximation of two-tailed p-value using the regularized incomplete beta function.
    # Uses a continued fraction approximation for the t-distribution CDF.
    def two_tailed_p_value(t_stat, df)
      x = df / (df + t_stat**2)
      # Regularized incomplete beta function I_x(a, b) where a=df/2, b=1/2
      p_one_tail = 0.5 * regularized_beta(x, df / 2.0, 0.5)
      [ 2.0 * p_one_tail, 1.0 ].min
    end

    # Approximation of the regularized incomplete beta function using a
    # continued fraction expansion (Lentz's algorithm).
    def regularized_beta(x, a, b)
      return 1.0 if x >= 1.0
      return 0.0 if x <= 0.0

      # Use the symmetry relation when x > (a+1)/(a+b+2) for convergence
      if x > (a + 1) / (a + b + 2)
        return 1.0 - regularized_beta(1.0 - x, b, a)
      end

      log_prefix = lgamma_sum(a, b) + a * Math.log(x) + b * Math.log(1.0 - x)
      prefix = Math.exp(log_prefix)

      prefix * continued_fraction(x, a, b) / a
    end

    def lgamma_sum(a, b)
      Math.lgamma(a + b)[0] - Math.lgamma(a)[0] - Math.lgamma(b)[0]
    end

    # Lentz's continued fraction for I_x(a, b)
    def continued_fraction(x, a, b)
      max_iter = 200
      epsilon = 1.0e-10
      tiny = 1.0e-30

      c = 1.0
      d = 1.0 / [ 1.0 - x * (a + b) / (a + 1), tiny ].max.abs
      result = d

      (1..max_iter).each do |m|
        # Even step
        numerator = m * (b - m) * x / ((a + 2 * m - 1) * (a + 2 * m))
        d = 1.0 / [ 1.0 + numerator * d, tiny ].max.abs
        c = [ 1.0 + numerator / c, tiny ].max.abs
        result *= d * c

        # Odd step
        numerator = -((a + m) * (a + b + m) * x) / ((a + 2 * m) * (a + 2 * m + 1))
        d = 1.0 / [ 1.0 + numerator * d, tiny ].max.abs
        c = [ 1.0 + numerator / c, tiny ].max.abs
        delta = d * c
        result *= delta

        break if (delta - 1.0).abs < epsilon
      end

      result
    end
  end
end
