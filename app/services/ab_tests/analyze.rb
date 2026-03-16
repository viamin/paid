# frozen_string_literal: true

module AbTests
  class Analyze
    include WelchTTest

    def self.call(...)
      new(...).call
    end

    def initialize(ab_test:)
      @ab_test = ab_test
    end

    def call
      return insufficient_data unless ab_test.reached_min_sample_size?

      variants = ab_test.variants.order(:id).to_a
      return insufficient_data if variants.size < 2

      # Control is the variant named "control"; falls back to lowest-id variant
      # if no variant is explicitly named "control".
      control = variants.find { |v| v.name == "control" } || variants.first
      best_variant = variants.max_by { |v| v.avg_quality_score.to_f }

      improvement = calculate_improvement(control, best_variant)
      confidence = calculate_confidence(control, best_variant)
      threshold = ab_test.confidence_level&.to_f || 0.95

      {
        status: confidence >= threshold ? :significant : :not_significant,
        winner: best_variant,
        control: control,
        confidence: confidence.round(4),
        improvement: improvement.round(2),
        variants: variants.map { |v| variant_summary(v) }
      }
    end

    private

    attr_reader :ab_test

    def insufficient_data
      {
        status: :insufficient_data,
        winner: nil,
        control: nil,
        confidence: 0.0,
        improvement: 0.0,
        variants: ab_test.variants.map { |v| variant_summary(v) }
      }
    end

    def variant_summary(variant)
      {
        id: variant.id,
        name: variant.name,
        sample_count: variant.sample_count,
        avg_quality_score: variant.avg_quality_score.to_f.round(4)
      }
    end

    def calculate_improvement(control, variant)
      return 0.0 if control.avg_quality_score.to_f.zero?
      return 0.0 if control == variant

      ((variant.avg_quality_score.to_f - control.avg_quality_score.to_f) / control.avg_quality_score.to_f * 100)
    end

    def calculate_confidence(control, variant)
      return 0.0 if control == variant
      return 0.0 if control.sample_count < 2 || variant.sample_count < 2

      welch_t_test_confidence(
        variant.avg_quality_score.to_f,
        control.avg_quality_score.to_f,
        variant_std_dev(variant),
        variant_std_dev(control),
        variant.sample_count.to_f,
        control.sample_count.to_f
      )
    end

    # Computes standard deviation from actual quality metric composite scores
    # for the variant's assigned agent runs.
    def variant_std_dev(variant)
      scores = QualityMetric
        .joins(agent_run: :ab_test_assignment)
        .where(ab_test_assignments: { ab_test_variant_id: variant.id })
        .where.not(composite_score: nil)
        .pluck(:composite_score)
        .map(&:to_f)

      return 0.25 if scores.size < 2

      mean = scores.sum / scores.size
      variance = scores.sum { |s| (s - mean)**2 } / (scores.size - 1)
      Math.sqrt(variance)
    end
  end
end
