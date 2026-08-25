# frozen_string_literal: true

module AbTests
  # Backwards-compatible alias for the shared Welch's t-test math primitives.
  # The implementation lives in Experiments::Statistics so all six
  # experiment frameworks share a single source of truth.
  module Statistics
    module_function

    def mean(values)
      Experiments::Statistics.mean(values)
    end

    def std_dev(values)
      Experiments::Statistics.std_dev(values)
    end

    def welch_t_test(group1, group2)
      Experiments::Statistics.welch_t_test(group1, group2)
    end

    def two_tailed_p_value(t_stat, df)
      Experiments::Statistics.two_tailed_p_value(t_stat, df)
    end

    def regularized_beta(x, a, b)
      Experiments::Statistics.regularized_beta(x, a, b)
    end

    def lgamma_sum(a, b)
      Experiments::Statistics.lgamma_sum(a, b)
    end

    def continued_fraction(x, a, b)
      Experiments::Statistics.continued_fraction(x, a, b)
    end
  end
end
