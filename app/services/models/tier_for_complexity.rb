# frozen_string_literal: true

module Models
  # Maps a complexity score (1-10) to an LlmModel tier ("low" | "mid" | "high")
  # using tunable thresholds. Thresholds are resolved from the first source that
  # defines them: project-level `model_preferences["complexity_thresholds"]`,
  # the agent_run's provider, or Provider::DEFAULT_COMPLEXITY_THRESHOLDS.
  #
  # Returns nil when the complexity score is nil or non-numeric — callers fall
  # back to their existing behavior when no tier can be derived.
  class TierForComplexity
    def self.call(...)
      new(...).call
    end

    def initialize(complexity:, agent_run: nil, project: nil, provider: nil)
      @complexity = complexity
      @agent_run = agent_run
      @project = project || agent_run&.project
      @provider = provider || agent_run&.provider
    end

    def call
      return nil if complexity.nil?

      score = Float(complexity)
      thresholds = effective_thresholds

      tier = if score <= thresholds["low_max"]
        "low"
      elsif score <= thresholds["mid_max"]
        "mid"
      else
        "high"
      end

      apply_project_tier_bounds(tier)
    rescue ArgumentError, TypeError
      nil
    end

    def effective_thresholds
      project_override || provider_thresholds || Provider::DEFAULT_COMPLEXITY_THRESHOLDS.dup
    end

    private

    attr_reader :complexity, :agent_run, :project, :provider

    def apply_project_tier_bounds(tier)
      tier = raise_to_minimum_tier(tier)
      cap_tier(tier)
    end

    def raise_to_minimum_tier(tier)
      minimum = project&.model_preferences&.dig("quality_recovery_min_tier")
      return tier unless minimum.present? && LlmModel::TIERS.include?(minimum)

      min_index = LlmModel::TIERS.index(minimum)
      tier_index = LlmModel::TIERS.index(tier)
      return tier unless tier_index

      tier_index >= min_index ? tier : minimum
    end

    def cap_tier(tier)
      max = project&.model_preferences&.dig("max_tier")
      return tier unless max.present? && LlmModel::TIERS.include?(max)

      max_index = LlmModel::TIERS.index(max)
      tier_index = LlmModel::TIERS.index(tier)
      return tier unless tier_index

      tier_index <= max_index ? tier : max
    end

    def project_override
      return nil unless project

      raw = project.model_preferences&.dig("complexity_thresholds")
      return nil unless raw.is_a?(Hash)

      normalized = Provider::DEFAULT_COMPLEXITY_THRESHOLDS.merge(
        raw.slice(*Provider::COMPLEXITY_THRESHOLD_KEYS)
      )
      normalized.transform_values { |v| Integer(v, exception: false) || v }
    end

    def provider_thresholds
      provider&.effective_complexity_thresholds
    end
  end
end
