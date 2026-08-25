# frozen_string_literal: true

module Experiments
  # Shared Welch's t-test analyzer used by every experiment framework whose
  # variants carry a numeric quality score. Each framework supplies the
  # experiment record and the assignment-association name; this service
  # handles the variant-vs-control math, sufficient-sample check, and
  # outcome classification.
  #
  # The analyzer expects the host experiment model to expose:
  #   * <variants_association>.order(:id) — ordered variant collection
  #   * a `min_samples_per_variant` numeric
  #   * a `confidence_threshold` numeric (0..1)
  #   * a `control_variant` shortcut (or use find_by(is_control: true))
  #
  # Variants must respond to:
  #   * `is_control` — true marks the baseline
  #   * `sample_count`
  #   * `<assignments_association>.where.not(<score_column>: nil).pluck(<score_column>)`
  #
  # Result.status:
  #   * :winner_found — a non-control variant beats control with confidence
  #   * :control_wins — all non-control variants are significantly worse
  #   * :no_significant_difference — comparison is inconclusive
  #   * :insufficient_data — not enough samples / no control
  class Analyze
    Result = Struct.new(:status, :winner, :confidence, :improvement, :details, keyword_init: true)

    def self.call(experiment:, variants_association:, assignments_association:, score_column: :quality_score)
      new(experiment:, variants_association:, assignments_association:, score_column:).analyze
    end

    def initialize(experiment:, variants_association:, assignments_association:, score_column:)
      @experiment = experiment
      @variants_association = variants_association
      @assignments_association = assignments_association
      @score_column = score_column
    end

    def analyze
      variants = experiment.public_send(variants_association).order(:id).to_a
      control = variants.find(&:is_control)

      return insufficient unless control
      return insufficient unless all_have_minimum_samples?(variants)

      control_scores = scores_for(control)
      return insufficient if control_scores.size < 2

      results = variants.reject(&:is_control).filter_map do |variant|
        result_for(control_scores, variant)
      end

      determine_outcome(results)
    end

    private

    attr_reader :experiment, :variants_association, :assignments_association, :score_column

    def insufficient
      Result.new(status: :insufficient_data)
    end

    def all_have_minimum_samples?(variants)
      threshold = experiment.min_samples_per_variant
      variants.all? { |variant| variant.sample_count >= threshold }
    end

    def scores_for(variant)
      variant.public_send(assignments_association)
          .where.not(score_column => nil)
          .pluck(score_column)
          .map(&:to_f)
    end

    def result_for(control_scores, variant)
      variant_scores = scores_for(variant)
      return nil if variant_scores.size < 2

      t_result = Statistics.welch_t_test(control_scores, variant_scores)
      return nil unless t_result

      {
        variant: variant,
        mean_diff: Statistics.mean(variant_scores) - Statistics.mean(control_scores),
        p_value: t_result[:p_value],
        significant: t_result[:p_value] < (1 - experiment.confidence_threshold)
      }
    end

    def determine_outcome(results)
      return insufficient if results.empty?

      significant_improvements = results.select { |r| r[:significant] && r[:mean_diff].positive? }

      if significant_improvements.any?
        winner = significant_improvements.max_by { |r| r[:mean_diff] }
        Result.new(
          status: :winner_found,
          winner: winner[:variant],
          confidence: 1 - winner[:p_value],
          improvement: winner[:mean_diff],
          details: results
        )
      elsif results.all? { |r| r[:significant] && r[:mean_diff].negative? }
        Result.new(status: :control_wins, details: results)
      else
        Result.new(status: :no_significant_difference, details: results)
      end
    end
  end
end
