# frozen_string_literal: true

module Models
  # Ranks remaining active, same-provider catalog candidates as a
  # policy-eligible replacement after a structured runtime rejection.
  #
  # Selection is entirely data-driven (tier proximity, then capability_score)
  # over the current catalog — it never hardcodes a specific model id (e.g.
  # gpt-5.2-codex) as a universal fallback, and it excludes any model already
  # known to be unavailable for the same context.
  #
  # @spec MODEL-AVAILABILITY-006
  class PolicyEligibleReplacement
    def self.call(...) = new(...).call

    def initialize(rejected_model:, excluded_model_ids: [])
      @rejected_model = rejected_model
      @excluded_model_ids = Array(excluded_model_ids).map(&:to_s).to_set.add(rejected_model.model_id)
    end

    def call
      candidates.min_by { |model| [ tier_distance(model), -model.capability_score.to_f ] }
    end

    private

    attr_reader :rejected_model, :excluded_model_ids

    def candidates
      LlmModel.active.by_provider(rejected_model.provider).where.not(model_id: excluded_model_ids.to_a)
    end

    def tier_distance(model)
      rejected_index = LlmModel::TIERS.index(rejected_model.tier)
      candidate_index = LlmModel::TIERS.index(model.tier)
      return Float::INFINITY if rejected_index.nil? || candidate_index.nil?

      (rejected_index - candidate_index).abs
    end
  end
end
