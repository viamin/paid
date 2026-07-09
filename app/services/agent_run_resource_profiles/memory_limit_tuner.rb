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
      # The tuner must reason about the *just-computed* window's OOM count,
      # not the value persisted on the profile (which is the previous
      # window's count). On a brand-new profile the persisted count is 0
      # while the new summary may show several OOMs; on an existing profile
      # the persisted count is stale. Either way the current observation is
      # authoritative — including when it is 0, which means the workload has
      # just had an OOM-free window. effective_oom_count distinguishes nil
      # ("caller passed nothing") from 0 ("no OOMs this window") so a stale
      # persisted count can't keep a recovered profile capacity-blocked.
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
        # Accrue consecutive_low against the *held* limit, not against
        # `target` (≈ p95 * SAFETY_MULTIPLIER). The cooldown test is
        # `p95 <= target * LOW_MEMORY_HEADROOM_RATIO`, but `target` is
        # built from p95 itself, so the inequality is unsatisfiable as
        # written: `target * 0.6 < p95 * 1.2 * 0.6 = p95 * 0.72`, and
        # `0.72 < 1`, meaning the freshly observed p95 is always above
        # the threshold. Scoring against `previous_limit` instead — the
        # held value the tuner is about to persist — measures "is this
        # workload comfortably below the limit we are keeping it at?",
        # which is the question that actually justifies dropping the
        # limit on a future refresh. previous_limit is guaranteed
        # positive here because `downward_move?` already required it.
        if low_memory_sample?(previous_limit)
          consecutive_low += 1
        else
          consecutive_low = 0
        end
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
      # Distinguish "absent" (nil — caller passed nothing, so fall back to
      # the persisted count) from "zero" (0 — the just-computed window had
      # no OOMs, which is the authoritative value for this refresh). A bare
      # truthiness check would treat 0 as absent and let stale persisted
      # OOM counts keep a profile capacity-blocked after it has recovered.
      return projected_oom_count.to_i unless projected_oom_count.nil?

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
