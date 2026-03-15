# frozen_string_literal: true

module AbTests
  # Welch's t-test implementation for comparing two sample means with
  # potentially unequal variances. Computes the t-statistic using
  # Welch-Satterthwaite degrees of freedom and returns a two-tailed
  # p-value via the regularized incomplete beta function.
  module WelchTTest
    private

    def welch_t_test_confidence(mean1, mean2, std_dev1, std_dev2, n1, n2)
      return 0.0 if n1 < 2 || n2 < 2

      mean_diff = (mean1 - mean2).abs
      return 0.0 if mean_diff.zero?

      se = Math.sqrt((std_dev1**2 / n1) + (std_dev2**2 / n2))
      return 0.0 if se.zero?

      t_stat = mean_diff / se
      df = welch_degrees_of_freedom(std_dev1, n1, std_dev2, n2)
      return 0.0 if df < 1

      p_value = two_tailed_t_p_value(t_stat, df)
      1.0 - p_value
    end

    def welch_degrees_of_freedom(s1, n1, s2, n2)
      v1 = s1**2 / n1
      v2 = s2**2 / n2
      numerator = (v1 + v2)**2
      denominator = (v1**2 / (n1 - 1)) + (v2**2 / (n2 - 1))
      return 1.0 if denominator.zero?

      numerator / denominator
    end

    def two_tailed_t_p_value(t_stat, df)
      x = df / (df + t_stat**2)
      1.0 - regularized_incomplete_beta(df / 2.0, 0.5, x).clamp(0.0, 1.0)
    end

    # Approximation of I_x(a, b) using continued fraction (Lentz's method).
    def regularized_incomplete_beta(a, b, x)
      return 0.0 if x <= 0.0
      return 1.0 if x >= 1.0

      if x > (a + 1.0) / (a + b + 2.0)
        return 1.0 - regularized_incomplete_beta(b, a, 1.0 - x)
      end

      log_prefix = a * Math.log(x) + b * Math.log(1.0 - x) - log_beta(a, b)
      beta_cf(a, b, x) * Math.exp(log_prefix) / a
    end

    def log_beta(a, b)
      Math.lgamma(a)[0] + Math.lgamma(b)[0] - Math.lgamma(a + b)[0]
    end

    def beta_cf(a, b, x, max_iter: 200, epsilon: 1e-10)
      qab = a + b
      c = 1.0
      d = 1.0 - qab * x / (a + 1.0)
      d = 1e-30 if d.abs < 1e-30
      d = 1.0 / d
      h = d

      (1..max_iter).each do |m|
        m2 = 2 * m
        aa = m * (b - m) * x / ((a + m2 - 1.0) * (a + m2))
        d = 1.0 + aa * d
        d = 1e-30 if d.abs < 1e-30
        c = 1.0 + aa / c
        c = 1e-30 if c.abs < 1e-30
        d = 1.0 / d
        h *= d * c

        aa = -(a + m) * (qab + m) * x / ((a + m2) * (a + m2 + 1.0))
        d = 1.0 + aa * d
        d = 1e-30 if d.abs < 1e-30
        c = 1.0 + aa / c
        c = 1e-30 if c.abs < 1e-30
        d = 1.0 / d
        delta = d * c
        h *= delta

        break if (delta - 1.0).abs < epsilon
      end

      h
    end
  end
end
