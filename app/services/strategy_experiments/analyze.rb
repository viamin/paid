# frozen_string_literal: true

module StrategyExperiments
  # Analyzes strategy experiment results using Welch's t-test to determine
  # if any variant is statistically significantly better than control.
  #
  # Thin delegating wrapper around Experiments::Analyze — the shared
  # analyzer handles variant/control math, sufficient-sample checks, and
  # outcome classification once for every experiment framework.
  class Analyze
    Result = Experiments::Analyze::Result

    def self.call(strategy_experiment:)
      Experiments::Analyze.call(
        experiment: strategy_experiment,
        variants_association: :strategy_experiment_variants,
        assignments_association: :strategy_experiment_assignments,
        score_column: :quality_score
      )
    end
  end
end
