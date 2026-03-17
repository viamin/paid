# frozen_string_literal: true

module AbTests
  # Pure math helpers for Welch's t-test and the regularized incomplete beta function.
  # Extracted from Analyze to keep the service focused on orchestration (per Sandi Metz size guidelines).
  module Statistics
    module_function

    def mean(values)
      values.sum / values.size.to_f
    end

    def std_dev(values)
      return 0.0 if values.size < 2

      m = mean(values)
      variance = values.sum { |v| (v - m)**2 } / (values.size - 1).to_f
      Math.sqrt(variance)
    end

    # Welch's t-test for two independent samples with possibly unequal variances.
    def welch_t_test(group1, group2)
      n1 = group1.size
      n2 = group2.size
      m1 = mean(group1)
      m2 = mean(group2)
      s1 = std_dev(group1)
      s2 = std_dev(group2)

      se = Math.sqrt((s1**2 / n1) + (s2**2 / n2))
      if se.zero?
        if m1 == m2
          return { t: 0.0, df: n1 + n2 - 2, p_value: 1.0 }
        else
          t = m1 < m2 ? -Float::INFINITY : Float::INFINITY
          return { t: t, df: n1 + n2 - 2, p_value: 0.0 }
        end
      end

      t = (m1 - m2) / se

      # Welch-Satterthwaite degrees of freedom
      numerator = ((s1**2 / n1) + (s2**2 / n2))**2
      denominator = ((s1**4 / (n1**2 * (n1 - 1))) + (s2**4 / (n2**2 * (n2 - 1))))
      df = denominator.zero? ? [ n1, n2 ].min - 1 : numerator / denominator

      df_for_p = df > 1e-9 ? df : 1e-9
      p_value = two_tailed_p_value(t.abs, df_for_p)
      { t: t, df: df, p_value: p_value }
    end

    # Approximation of two-tailed p-value using the regularized incomplete beta function.
    def two_tailed_p_value(t_stat, df)
      x = df / (df + t_stat**2)
      p_one_tail = 0.5 * regularized_beta(x, df / 2.0, 0.5)
      [ 2.0 * p_one_tail, 1.0 ].min
    end

    # Regularized incomplete beta function using Lentz's continued fraction expansion.
    def regularized_beta(x, a, b)
      return 1.0 if x >= 1.0
      return 0.0 if x <= 0.0

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
      denom = 1.0 - x * (a + b) / (a + 1)
      denom = tiny if denom.abs < tiny
      d = 1.0 / denom
      result = d

      (1..max_iter).each do |m|
        # Even step
        numerator = m * (b - m) * x / ((a + 2 * m - 1) * (a + 2 * m))
        denom = 1.0 + numerator * d
        denom = tiny if denom.abs < tiny
        d = 1.0 / denom
        c_denom = 1.0 + numerator / c
        c_denom = tiny if c_denom.abs < tiny
        c = c_denom
        result *= d * c

        # Odd step
        numerator = -((a + m) * (a + b + m) * x) / ((a + 2 * m) * (a + 2 * m + 1))
        denom = 1.0 + numerator * d
        denom = tiny if denom.abs < tiny
        d = 1.0 / denom
        c_denom = 1.0 + numerator / c
        c_denom = tiny if c_denom.abs < tiny
        c = c_denom
        delta = d * c
        result *= delta

        break if (delta - 1.0).abs < epsilon
      end

      result
    end
  end
end
