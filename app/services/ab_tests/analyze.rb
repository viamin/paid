# frozen_string_literal: true

module AbTests
  class Analyze
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

    # Simplified confidence calculation using a normal approximation heuristic.
    # This is NOT a Welch's t-test; it uses an estimated SE based on assumed
    # score range [0,1]. Sufficient for early-stage analysis with small samples;
    # replace with Welch's t-test when per-observation data is available.
    def calculate_confidence(control, variant)
      return 0.0 if control == variant
      return 0.0 if control.sample_count < 2 || variant.sample_count < 2

      mean_diff = (variant.avg_quality_score.to_f - control.avg_quality_score.to_f).abs
      return 0.0 if mean_diff.zero?

      # Estimate standard error using sample size and score range
      se_control = estimated_se(control)
      se_variant = estimated_se(variant)
      pooled_se = Math.sqrt(se_control**2 + se_variant**2)

      return 0.0 if pooled_se.zero?

      z_score = mean_diff / pooled_se
      # Convert z-score to confidence using error function approximation
      confidence_from_z(z_score)
    end

    def estimated_se(variant)
      # Estimate SE as score_range / sqrt(n), assuming scores in [0,1]
      return 1.0 if variant.sample_count < 2

      0.25 / Math.sqrt(variant.sample_count)
    end

    def confidence_from_z(z)
      # Approximation of 1 - 2*(1-Phi(z)) for two-tailed test
      # Using the complementary error function approximation
      t = 1.0 / (1.0 + 0.2316419 * z.abs)
      d = 0.3989422804014327
      p = d * Math.exp(-z * z / 2.0) * t *
        (0.3193815 + t * (-0.3565638 + t * (1.781478 + t * (-1.821256 + t * 1.330274))))
      z > 0 ? 1.0 - 2.0 * p : 0.0
    end
  end
end
