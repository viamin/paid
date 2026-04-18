# frozen_string_literal: true

module PromptEvolution
  # Composite fitness score for a prompt variant. Combines three dimensions
  # so evolutionary selection rewards prompts that produce high-quality
  # output without being prohibitively expensive or slow:
  #
  #   * quality   — average composite quality score (0..1) across samples
  #   * cost      — normalized inverse of cost_cents
  #   * speed     — normalized inverse of duration_seconds
  #
  # Cost and speed use a saturating transform so absolute values can be
  # compared across prompts without min/max anchoring to the current
  # batch (which would make scores incomparable across runs):
  #
  #   normalized = reference / (value + reference)
  #
  # That maps [0, ∞) → (0, 1], with `reference` as the half-point so the
  # tunable controls "what counts as expensive/slow" instead of leaking
  # in a moving baseline. Returns 1.0 when the value is zero, 0.5 when
  # value equals reference, and approaches 0 as value grows.
  #
  # @example
  #   result = PromptEvolution::FitnessFunction.call(samples: samples, project: project)
  #   result.composite_fitness   # => 0.7321
  #   result.quality_score       # => 0.85
  #   result.cost_score          # => 0.6667
  #   result.speed_score         # => 0.5
  class FitnessFunction
    DEFAULT_WEIGHTS = { quality: 0.6, cost: 0.2, speed: 0.2 }.freeze
    DIMENSIONS = DEFAULT_WEIGHTS.keys.freeze

    DEFAULT_REFERENCE_COST_CENTS = 100        # $1.00 — half-point penalty
    DEFAULT_REFERENCE_DURATION_SECONDS = 600  # 10 minutes — half-point penalty

    Result = Struct.new(
      :composite_fitness,
      :quality_score,
      :cost_score,
      :speed_score,
      :sample_count,
      :weights,
      :reference_cost_cents,
      :reference_duration_seconds,
      keyword_init: true
    )

    class << self
      def call(samples:, project: nil, weights: nil,
               reference_cost_cents: nil, reference_duration_seconds: nil)
        new(
          samples: samples,
          project: project,
          weights: weights,
          reference_cost_cents: reference_cost_cents,
          reference_duration_seconds: reference_duration_seconds
        ).score
      end
    end

    def initialize(samples:, project: nil, weights: nil,
                   reference_cost_cents: nil, reference_duration_seconds: nil)
      @samples = Array(samples)
      @project = project
      @weights = normalize_weights(resolve_weights(weights))
      @reference_cost_cents = positive_or_default(
        reference_cost_cents || project_setting("reference_cost_cents"),
        DEFAULT_REFERENCE_COST_CENTS
      )
      @reference_duration_seconds = positive_or_default(
        reference_duration_seconds || project_setting("reference_duration_seconds"),
        DEFAULT_REFERENCE_DURATION_SECONDS
      )
    end

    # Returns a Result with each dimension's normalized score and the
    # weighted composite. Returns zero scores (rather than nil) for an
    # empty sample set so callers can sort and compare consistently.
    def score
      quality = aggregate_quality
      cost = aggregate_cost_score
      speed = aggregate_speed_score
      composite = (@weights[:quality] * quality) +
        (@weights[:cost] * cost) +
        (@weights[:speed] * speed)

      Result.new(
        composite_fitness: composite.round(4),
        quality_score: quality.round(4),
        cost_score: cost.round(4),
        speed_score: speed.round(4),
        sample_count: @samples.size,
        weights: @weights,
        reference_cost_cents: @reference_cost_cents,
        reference_duration_seconds: @reference_duration_seconds
      )
    end

    private

    def aggregate_quality
      values = @samples.filter_map { |s| sample_value(s, :composite_score) }
        .map { |v| v.to_f.clamp(0.0, 1.0) }
      return 0.0 if values.empty?

      values.sum / values.size
    end

    def aggregate_cost_score
      values = @samples.filter_map { |s| sample_value(s, :cost_cents) }
        .map { |v| normalize_inverse(v, @reference_cost_cents) }
      return 0.0 if values.empty?

      values.sum / values.size
    end

    def aggregate_speed_score
      values = @samples.filter_map { |s| sample_value(s, :duration_seconds) }
        .map { |v| normalize_inverse(v, @reference_duration_seconds) }
      return 0.0 if values.empty?

      values.sum / values.size
    end

    # Saturating inverse: ref / (value + ref). Maps [0, ∞) → (0, 1]
    # so larger values (more cost / longer duration) score lower.
    def normalize_inverse(value, reference)
      v = [ value.to_f, 0.0 ].max
      ref = reference.to_f
      ref / (v + ref)
    end

    def sample_value(sample, key)
      if sample.is_a?(Hash)
        sample.key?(key) ? sample[key] : sample[key.to_s]
      elsif sample.respond_to?(key)
        sample.public_send(key)
      end
    end

    def resolve_weights(explicit)
      return explicit if explicit.is_a?(Hash) && explicit.any?

      project_weights = project_setting("weights")
      return project_weights if project_weights.is_a?(Hash) && project_weights.any?

      DEFAULT_WEIGHTS
    end

    # Coerces user-supplied weights into a normalized DIMENSIONS-keyed hash
    # whose values sum to 1.0. Missing or non-numeric entries fall back to
    # DEFAULT_WEIGHTS for that dimension; if the resulting total is zero
    # (e.g. all weights set to 0), defaults are used instead so the
    # composite score remains meaningful.
    def normalize_weights(raw)
      coerced = DIMENSIONS.each_with_object({}) do |dim, out|
        value = raw[dim] || raw[dim.to_s] if raw.is_a?(Hash)
        numeric = Float(value, exception: false)
        out[dim] = numeric && numeric >= 0 ? numeric : DEFAULT_WEIGHTS[dim].to_f
      end

      total = coerced.values.sum
      return DEFAULT_WEIGHTS.dup if total.zero?

      coerced.transform_values { |v| (v / total).round(6) }
    end

    def project_setting(key)
      return nil unless @project.respond_to?(:fitness_settings)

      settings = @project.fitness_settings
      return nil unless settings.is_a?(Hash)

      settings.key?(key) ? settings[key] : settings[key.to_sym]
    end

    def positive_or_default(value, fallback)
      numeric = Float(value, exception: false)
      numeric && numeric.positive? ? numeric : fallback.to_f
    end
  end
end
