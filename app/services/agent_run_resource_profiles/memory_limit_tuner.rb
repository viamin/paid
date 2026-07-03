# frozen_string_literal: true

module AgentRunResourceProfiles
  # Decides the final recommended memory limit for a resource profile
  # after a refresh. The raw baseline recommendation computed from
  # observed peaks and OOM bumps is post-processed here so that:
  #
  # * the value stays inside the per-user floor/ceiling band;
  # * downward moves require sustained low-memory samples (no oscillation);
  # * repeated OOMs near the ceiling transition the profile into
  #   capacity_blocked so the recommended limit stops chasing Docker memory.
  #
  # The tuner is intentionally pure: it reads the existing profile and
  # the baseline computed in RefreshForRun, and returns a Decision with
  # all the columns the caller needs to persist.
  class MemoryLimitTuner
    Decision = Struct.new(
      :recommended_limit_bytes,
      :capacity_blocked,
      :capacity_blocked_at,
      :consecutive_low_memory_samples,
      :downward_tuning_count,
      :floor_bytes,
      :ceiling_bytes,
      :previous_downward_tuning_count,
      keyword_init: true
    ) do
      alias_method :capacity_blocked?, :capacity_blocked

      def downward_tuned?
        downward_tuning_count.to_i > previous_downward_tuning_count.to_i
      end
    end

    def initialize(profile:, user_settings:, baseline_limit_bytes:, p95_memory_bytes:, projected_oom_count: nil)
      @profile = profile
      @user_settings = user_settings
      @baseline_limit_bytes = baseline_limit_bytes.to_i
      # The tuner's cooldown logic depends on the *just-computed* p95, not
      # the value persisted on the profile. For a brand-new profile
      # `profile.p95_memory_bytes` is 0 (so the `positive?` guard would
      # short-circuit and no sample could ever count as low-memory), and
      # for an existing profile it is the p95 from the previous refresh.
      # Either way it ignores the current observation. RefreshForRun
      # passes the freshly computed p95 in here so the consecutive_low
      # counter reflects the sample that just came in.
      @p95_memory_bytes = p95_memory_bytes.to_i
      # In a brand-new profile the persisted oom_count is 0 even though
      # the just-computed summary may show several OOMs. The tuner must
      # consider the projected value when deciding whether to mark the
      # profile capacity-blocked on the very first refresh.
      @projected_oom_count = projected_oom_count
    end

    def call
      floor = floor_bytes
      ceiling = ceiling_bytes
      previous_limit = @profile.recommended_memory_limit_bytes.to_i
      target = clamp(@baseline_limit_bytes, floor: floor, ceiling: ceiling)

      consecutive_low = @profile.consecutive_low_memory_samples.to_i
      downward_tuning_count = @profile.downward_tuning_count.to_i
      capacity_blocked = @profile.capacity_blocked?
      capacity_blocked_at = @profile.capacity_blocked_at

      if downward_move?(previous_limit, target) && !downward_tune_authorized?
        # This branch fires when the baseline dropped *below* the current
        # limit (observed usage fell, so a downward move is requested) but
        # we have not yet banked enough sustained low-memory samples to
        # trust the lower number. Hold the limit so a single transient dip
        # — e.g. one high-peak run aging out of the lookback window — can't
        # collapse it.
        #
        # The consecutive counter is reset here on purpose. It is meant to
        # accrue during *stable* windows where the baseline stays at or
        # above the current limit (the else branch below). A baseline that
        # dips below the limit is exactly the transitional trigger we are
        # being cautious about, so it restarts the cooldown instead of
        # counting toward the very lowering it would cause. Authorization
        # can therefore only come from low usage observed while the limit
        # was held steady, never from the dip itself.
        consecutive_low = 0
        # Hold at the previous limit, but never above the current ceiling.
        # If an operator lowers container_memory_auto_ceiling_bytes while a
        # recommendation is already in flight, previous_limit can sit above
        # the new ceiling; honouring it verbatim would persist a value
        # outside the operator-controllable band.
        target = [ previous_limit, ceiling ].min
      elsif capacity_blocked_eligible? && should_block_capacity?(target, ceiling)
        capacity_blocked = true
        capacity_blocked_at ||= Time.current
        # Pin to the previous limit so the recommendation stops chasing
        # Docker memory upward — but still clamp it to the ceiling so a
        # lowered ceiling remains an effective escape hatch for a blocked
        # profile. When there is no prior limit yet, start at the top of
        # the band (capacity is already the binding constraint).
        target = previous_limit.positive? ? [ previous_limit, ceiling ].min : [ ceiling, floor ].max
      else
        if downward_move?(previous_limit, target)
          downward_tuning_count += 1
        end

        if low_memory_sample?(target)
          consecutive_low += 1
        else
          consecutive_low = 0
        end

        if capacity_blocked && !still_capacity_blocked?(target, ceiling)
          capacity_blocked = false
          capacity_blocked_at = nil
        end
      end

      Decision.new(
        recommended_limit_bytes: target,
        capacity_blocked: capacity_blocked,
        capacity_blocked_at: capacity_blocked_at,
        consecutive_low_memory_samples: consecutive_low,
        downward_tuning_count: downward_tuning_count,
        floor_bytes: floor,
        ceiling_bytes: ceiling,
        previous_downward_tuning_count: profile.downward_tuning_count.to_i
      )
    end

    private

    attr_reader :profile, :user_settings, :baseline_limit_bytes, :p95_memory_bytes, :projected_oom_count

    def floor_bytes
      [ user_floor, AgentRunResourceProfile::MIN_RECOMMENDED_MEMORY_LIMIT_BYTES ].max
    end

    def ceiling_bytes
      [ user_ceiling, floor_bytes + 1 ].max
    end

    def user_floor
      bytes = user_settings&.container_memory_auto_floor_bytes.to_i
      bytes.positive? ? bytes : UserSetting::DEFAULT_CONTAINER_MEMORY_AUTO_FLOOR_BYTES
    end

    def user_ceiling
      bytes = user_settings&.container_memory_auto_ceiling_bytes.to_i
      bytes.positive? ? bytes : UserSetting::DEFAULT_CONTAINER_MEMORY_AUTO_CEILING_BYTES
    end

    def clamp(value, floor:, ceiling:)
      return floor if floor >= ceiling

      value.to_i.clamp(floor, ceiling)
    end

    # A downward move is only allowed when the requested target is
    # meaningfully below the existing recommendation AND we have
    # accumulated enough consecutive low-memory samples to trust the
    # lower number.
    def downward_move?(previous_limit, target)
      previous_limit.positive? && target < previous_limit
    end

    def downward_tune_authorized?
      profile.consecutive_low_memory_samples.to_i >=
        AgentRunResourceProfile::DOWNWARD_TUNING_MIN_SAMPLES
    end

    def low_memory_sample?(target)
      threshold = (target * AgentRunResourceProfile::LOW_MEMORY_HEADROOM_RATIO).ceil
      p95_memory_bytes.positive? && p95_memory_bytes <= threshold
    end

    def capacity_blocked_eligible?
      effective_oom_count.to_i >= AgentRunResourceProfile::CAPACITY_BLOCKED_OOM_THRESHOLD
    end

    def effective_oom_count
      return projected_oom_count if projected_oom_count

      profile.oom_count.to_i
    end

    def should_block_capacity?(target, ceiling)
      target >= ceiling
    end

    def still_capacity_blocked?(target, ceiling)
      target >= ceiling
    end
  end
end
