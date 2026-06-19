# frozen_string_literal: true

module FreeModels
  # Selects the next free-model to retry within the openrouter_free runner
  # after a rate-limit error. Walks tiers starting at the supplied
  # `current_tier` and downward (high -> mid -> low), replacing the
  # rate-limited model with the highest-capability candidate that is
  # available (active, not user-excluded, not below the quality bar, and
  # not itself marked rate-limited in the runner's RunnerState).
  #
  # Signals exhaustion via Result#exhausted? when no candidate remains so
  # callers can fall back to the next runner in the chain and surface a
  # user-visible message.
  class Rotation
    Result = Struct.new(:rotated, :exhausted, :runner, :model_id, :previous_model_id,
      :tier, keyword_init: true) do
      def rotated? = rotated == true
      def exhausted? = exhausted == true
    end

    def self.call(...)
      new(...).call
    end

    # @param runner [Runner] The openrouter_free runner whose current model
    #   was rate-limited.
    # @param current_model_id [String, nil] The model id that just failed.
    # @param current_tier [String, nil] The tier the failed call was running
    #   at. When nil we infer the highest tier configured on the runner.
    # @param user [User, nil] Owning user; required to read the runner's
    #   RunnerState.
    # @param project [Project, nil] When present, respects that project's
    #   `model_preferences["excluded_free_model_ids"]` opt-outs.
    # @param include_below_quality_bar [Boolean] When true, models flagged
    #   with `below_quality_bar` in their metadata are still considered.
    def initialize(runner:, current_model_id: nil, current_tier: nil, user: nil,
      project: nil, include_below_quality_bar: false)
      @runner = runner
      @current_model_id = current_model_id
      @current_tier = current_tier
      @user = user
      @project = project
      @include_below_quality_bar = include_below_quality_bar
    end

    def call
      return exhausted_result unless openrouter_free?

      previous_model_id = effective_current_model_id
      runner_state = find_runner_state

      ordered_tiers.each do |tier|
        # The "current" model in this tier is whatever the runner is
        # currently configured for; we skip it so rotation actually moves
        # to a new model rather than re-selecting the one that just failed.
        tier_current_model_id = runner.tier_model_ids&.dig(tier)
        # The rate-limited model from the originating tier should be
        # skipped in every tier so we do not pick a known-bad model.
        skip_ids = [ previous_model_id, tier_current_model_id ].compact.uniq

        candidate = next_candidate_for(tier: tier, skip_ids: skip_ids,
          runner_state: runner_state)
        next unless candidate

        apply_rotation!(tier: tier, model: candidate)

        return Result.new(
          rotated: true,
          exhausted: false,
          runner: runner,
          model_id: candidate.model_id,
          previous_model_id: previous_model_id,
          tier: tier
        )
      end

      exhausted_result(previous_model_id: previous_model_id)
    end

    private

    attr_reader :runner, :user, :project

    def openrouter_free?
      runner&.runner_key == Runner::OPENROUTER_FREE_RUNNER_KEY
    end

    def exhausted_result(previous_model_id: nil)
      Result.new(
        rotated: false,
        exhausted: true,
        runner: runner,
        model_id: nil,
        previous_model_id: previous_model_id,
        tier: nil
      )
    end

    def effective_current_model_id
      return @current_model_id if @current_model_id.present?

      tier = resolved_current_tier
      return nil unless tier

      runner.tier_model_ids&.dig(tier)
    end

    # Walks tiers starting at the current_tier (or the highest configured
    # tier when no current_tier was supplied), then continues downward. If
    # no tier is configured at all we fall back to the global LlmModel::TIERS
    # order so rotation still produces a useful result on misconfigured
    # runners.
    def ordered_tiers
      configured = configured_tiers
      return LlmModel::TIERS.reverse.dup if configured.empty?

      valid_tiers = LlmModel::TIERS.reverse & configured
      return configured if valid_tiers.empty?

      start_index = valid_tiers.index(resolved_current_tier) || 0
      valid_tiers[start_index..] || valid_tiers
    end

    def resolved_current_tier
      return @current_tier.to_s if @current_tier.present?

      highest_configured_tier
    end

    # Highest configured tier (high -> mid -> low), independent of the
    # storage/hash key order of tier_model_ids. Used as the starting point
    # for walking tiers downward when the caller did not supply a tier.
    def highest_configured_tier
      (LlmModel::TIERS.reverse & configured_tiers).first || configured_tiers.first
    end

    def configured_tiers
      (runner.tier_model_ids || {}).keys.map(&:to_s)
    end

    def next_candidate_for(tier:, skip_ids:, runner_state:)
      excluded = excluded_model_ids
      rate_limited = runner_state&.rate_limited_model_ids || Set.new
      forbidden = (skip_ids + excluded).compact.uniq

      scope = LlmModel.free.active.by_tier(tier).by_capability
      scope = scope.where.not(model_id: forbidden) if forbidden.any?
      scope = scope.where.not(model_id: rate_limited.to_a) if rate_limited.any?

      scope.each do |model|
        next if forbidden.include?(model.model_id)
        next if !@include_below_quality_bar && model.below_quality_bar?

        return model
      end

      nil
    end

    def excluded_model_ids
      ids = []

      preferences = project&.model_preferences
      ids.concat(Array(preferences["excluded_free_model_ids"])) if preferences.is_a?(Hash)

      ids.compact.map(&:to_s).uniq
    end

    def find_runner_state
      return nil unless user

      user.runner_states.find_by(runner_name: runner.state_key)
    end

    def apply_rotation!(tier:, model:)
      next_tier_model_ids = (runner.tier_model_ids || {}).dup
      next_tier_model_ids[tier] = model.model_id
      runner.update!(tier_model_ids: next_tier_model_ids)
      # Per-model rate-limit windows are intentionally left intact here. They
      # are pruned of stale entries on read (RunnerState#rate_limited_model_ids)
      # and cleared wholesale only on a successful call (RunnerState#record_success!),
      # so wiping them now would let a just-rate-limited model be re-picked on
      # the next rotation.
    end
  end
end
