# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRunResourceProfiles::MemoryLimitTuner do
  let(:user_settings) do
    build(
      :user_setting,
      user: build(:user),
      container_memory_auto_floor_bytes: 512.megabytes,
      container_memory_auto_ceiling_bytes: 16.gigabytes
    )
  end

  let(:profile) do
    AgentRunResourceProfile.new(
      profile_level: "specific",
      lookup_key: "specific:account=1:project=1:runner=claude:goal=create_pr",
      sample_count: 3,
      p50_memory_bytes: 2.gigabytes,
      p95_memory_bytes: 3.gigabytes,
      max_memory_bytes: 3.gigabytes,
      oom_count: 0,
      consecutive_low_memory_samples: 0,
      downward_tuning_count: 0,
      recommended_memory_limit_bytes: 4.gigabytes
    )
  end

  describe "#call" do
    it "clamps the baseline into the auto floor/ceiling band" do
      profile.recommended_memory_limit_bytes = 0

      decision = described_class.new(
        profile: profile,
        user_settings: user_settings,
        baseline_limit_bytes: 64.gigabytes,
        p95_memory_bytes: 64.gigabytes
      ).call

      expect(decision.recommended_limit_bytes).to eq(16.gigabytes)
      expect(decision.floor_bytes).to eq(512.megabytes)
      expect(decision.ceiling_bytes).to eq(16.gigabytes)
    end

    it "grows the recommendation when OOM bumps push the baseline above the existing limit" do
      profile.recommended_memory_limit_bytes = 3.gigabytes

      decision = described_class.new(
        profile: profile,
        user_settings: user_settings,
        baseline_limit_bytes: 6.gigabytes,
        p95_memory_bytes: 5.gigabytes
      ).call

      expect(decision.recommended_limit_bytes).to eq(6.gigabytes)
      expect(decision.capacity_blocked?).to be(false)
    end

    it "marks the profile capacity-blocked when OOMs persist near the ceiling" do
      profile.recommended_memory_limit_bytes = 15.gigabytes
      profile.oom_count = AgentRunResourceProfile::CAPACITY_BLOCKED_OOM_THRESHOLD

      decision = described_class.new(
        profile: profile,
        user_settings: user_settings,
        baseline_limit_bytes: 17.gigabytes,
        p95_memory_bytes: 14.gigabytes
      ).call

      expect(decision.capacity_blocked?).to be(true)
      expect(decision.capacity_blocked_at).to be_present
      expect(decision.recommended_limit_bytes).to eq(15.gigabytes)
    end

    it "does not mark the profile capacity-blocked from stale persisted OOMs when the current window is OOM-free" do
      # Regression: projected_oom_count is the just-computed window's OOM count
      # and may legitimately be 0. A truthiness guard would treat that 0 as
      # "not provided" and fall back to the stale persisted profile.oom_count,
      # marking a profile capacity-blocked even after it has recovered into an
      # OOM-free window. The nil-vs-0 distinction is what keeps that from
      # happening.
      profile.recommended_memory_limit_bytes = 16.gigabytes
      profile.oom_count = AgentRunResourceProfile::CAPACITY_BLOCKED_OOM_THRESHOLD # stale

      decision = described_class.new(
        profile: profile,
        user_settings: user_settings,
        baseline_limit_bytes: 17.gigabytes, # clamps to the 16 GB ceiling
        p95_memory_bytes: 16.gigabytes,      # still peaking at the ceiling
        projected_oom_count: 0               # current window is OOM-free
      ).call

      expect(decision.capacity_blocked?).to be(false)
    end

    it "uses the persisted oom_count when no projected count is provided" do
      # The nil fallback path: when RefreshForRun cannot supply a projected
      # count (e.g. a brand-new tuner invocation in tests), the persisted
      # profile.oom_count remains authoritative for capacity decisions.
      profile.recommended_memory_limit_bytes = 15.gigabytes
      profile.oom_count = AgentRunResourceProfile::CAPACITY_BLOCKED_OOM_THRESHOLD

      decision = described_class.new(
        profile: profile,
        user_settings: user_settings,
        baseline_limit_bytes: 17.gigabytes,
        p95_memory_bytes: 14.gigabytes
        # projected_oom_count omitted on purpose
      ).call

      expect(decision.capacity_blocked?).to be(true)
    end

    it "does not grow past the existing limit once the profile is capacity-blocked" do
      profile.recommended_memory_limit_bytes = 16.gigabytes
      profile.oom_count = AgentRunResourceProfile::CAPACITY_BLOCKED_OOM_THRESHOLD
      profile.capacity_blocked = true
      profile.capacity_blocked_at = 1.minute.ago

      decision = described_class.new(
        profile: profile,
        user_settings: user_settings,
        baseline_limit_bytes: 20.gigabytes,
        p95_memory_bytes: 18.gigabytes
      ).call

      expect(decision.recommended_limit_bytes).to eq(16.gigabytes)
      expect(decision.capacity_blocked?).to be(true)
    end

    it "drops a capacity-blocked recommendation down to a newly lowered ceiling" do
      # The profile is already capacity-blocked at 16 GB and the operator
      # subsequently lowers container_memory_auto_ceiling_bytes to 8 GB to
      # force the limit down. The ceiling must remain an effective escape
      # hatch: the persisted recommendation cannot stay parked above the
      # new ceiling just because the profile is blocked.
      #
      # The downward move is authorized (enough sustained low-memory
      # samples) so the cooldown-hold branch is skipped and execution
      # reaches the capacity-blocked branch, which is the line that
      # previously re-pinned target to the stale previous_limit.
      profile.recommended_memory_limit_bytes = 16.gigabytes
      profile.oom_count = AgentRunResourceProfile::CAPACITY_BLOCKED_OOM_THRESHOLD
      profile.capacity_blocked = true
      profile.capacity_blocked_at = 1.minute.ago
      profile.consecutive_low_memory_samples = AgentRunResourceProfile::DOWNWARD_TUNING_MIN_SAMPLES
      lowered_settings = build(
        :user_setting,
        user: build(:user),
        container_memory_auto_floor_bytes: 512.megabytes,
        container_memory_auto_ceiling_bytes: 8.gigabytes
      )

      decision = described_class.new(
        profile: profile,
        user_settings: lowered_settings,
        baseline_limit_bytes: 17.gigabytes,
        p95_memory_bytes: 14.gigabytes
      ).call

      expect(decision.recommended_limit_bytes).to eq(8.gigabytes)
      expect(decision.ceiling_bytes).to eq(8.gigabytes)
      expect(decision.capacity_blocked?).to be(true)
    end

    it "respects a lowered ceiling while holding during the downward cooldown" do
      # Same class of issue as the capacity-blocked case: a downward move is
      # requested but not yet authorized, so we hold near the previous limit.
      # If that previous limit now exceeds a lowered ceiling, the hold must
      # still come down to the ceiling rather than persisting above the band.
      profile.recommended_memory_limit_bytes = 15.gigabytes
      profile.consecutive_low_memory_samples = 0
      profile.oom_count = 0
      lowered_settings = build(
        :user_setting,
        user: build(:user),
        container_memory_auto_floor_bytes: 512.megabytes,
        container_memory_auto_ceiling_bytes: 8.gigabytes
      )

      decision = described_class.new(
        profile: profile,
        user_settings: lowered_settings,
        baseline_limit_bytes: 7.gigabytes,
        p95_memory_bytes: 7.gigabytes
      ).call

      expect(decision.recommended_limit_bytes).to eq(8.gigabytes)
      expect(decision.downward_tuning_count).to eq(0)
    end

    it "clears capacity_blocked when the latest recommendation drops well below the ceiling" do
      profile.recommended_memory_limit_bytes = 4.gigabytes
      profile.oom_count = 0
      profile.capacity_blocked = true
      profile.capacity_blocked_at = 1.day.ago

      decision = described_class.new(
        profile: profile,
        user_settings: user_settings,
        baseline_limit_bytes: 4.gigabytes,
        p95_memory_bytes: 3.gigabytes
      ).call

      expect(decision.capacity_blocked?).to be(false)
      expect(decision.capacity_blocked_at).to be_nil
    end

    it "tracks consecutive low-memory samples" do
      profile.recommended_memory_limit_bytes = 8.gigabytes

      decision = described_class.new(
        profile: profile,
        user_settings: user_settings,
        baseline_limit_bytes: 8.gigabytes,
        p95_memory_bytes: (8.gigabytes * AgentRunResourceProfile::LOW_MEMORY_HEADROOM_RATIO) - 64.megabytes
      ).call

      expect(decision.consecutive_low_memory_samples).to eq(1)
    end

    it "resets the consecutive counter when the latest sample is not low" do
      profile.recommended_memory_limit_bytes = 4.gigabytes
      profile.consecutive_low_memory_samples = 4

      decision = described_class.new(
        profile: profile,
        user_settings: user_settings,
        baseline_limit_bytes: 5.gigabytes,
        p95_memory_bytes: 4.gigabytes
      ).call

      expect(decision.consecutive_low_memory_samples).to eq(0)
    end

    it "refuses to tune downward until enough sustained low-memory samples exist" do
      profile.recommended_memory_limit_bytes = 8.gigabytes
      profile.consecutive_low_memory_samples = AgentRunResourceProfile::DOWNWARD_TUNING_MIN_SAMPLES - 1
      profile.downward_tuning_count = 0

      decision = described_class.new(
        profile: profile,
        user_settings: user_settings,
        baseline_limit_bytes: 5.gigabytes,
        p95_memory_bytes: (8.gigabytes * AgentRunResourceProfile::LOW_MEMORY_HEADROOM_RATIO) - 64.megabytes
      ).call

      expect(decision.recommended_limit_bytes).to eq(8.gigabytes)
      expect(decision.downward_tuning_count).to eq(0)
      expect(decision.downward_tuned?).to be(false)
    end

    it "tunes downward after the sustained low-memory threshold is reached" do
      profile.recommended_memory_limit_bytes = 8.gigabytes
      profile.consecutive_low_memory_samples = AgentRunResourceProfile::DOWNWARD_TUNING_MIN_SAMPLES + 1
      profile.downward_tuning_count = 0

      decision = described_class.new(
        profile: profile,
        user_settings: user_settings,
        baseline_limit_bytes: 5.gigabytes,
        p95_memory_bytes: (8.gigabytes * AgentRunResourceProfile::LOW_MEMORY_HEADROOM_RATIO) - 64.megabytes
      ).call

      expect(decision.recommended_limit_bytes).to eq(5.gigabytes)
      expect(decision.downward_tuning_count).to eq(1)
      expect(decision.downward_tuned?).to be(true)
    end

    it "uses default floor/ceiling when user settings are missing" do
      profile.recommended_memory_limit_bytes = 0

      decision = described_class.new(
        profile: profile,
        user_settings: nil,
        baseline_limit_bytes: 32.gigabytes,
        p95_memory_bytes: 32.gigabytes
      ).call

      expect(decision.floor_bytes).to eq(UserSetting::DEFAULT_CONTAINER_MEMORY_AUTO_FLOOR_BYTES)
      expect(decision.ceiling_bytes).to eq(UserSetting::DEFAULT_CONTAINER_MEMORY_AUTO_CEILING_BYTES)
      expect(decision.recommended_limit_bytes).to eq(UserSetting::DEFAULT_CONTAINER_MEMORY_AUTO_CEILING_BYTES)
    end

    it "refuses to apply a baseline below the floor" do
      profile.recommended_memory_limit_bytes = 0

      decision = described_class.new(
        profile: profile,
        user_settings: user_settings,
        baseline_limit_bytes: 64.megabytes,
        p95_memory_bytes: 32.megabytes
      ).call

      expect(decision.recommended_limit_bytes).to eq(512.megabytes)
    end

    it "uses the freshly computed p95 instead of the persisted profile p95 to score low-memory samples" do
      # The profile attribute is the previous refresh's p95; the tuner must
      # read from the value passed in for the just-computed sample so the
      # consecutive counter actually reflects the new observation.
      profile.recommended_memory_limit_bytes = 8.gigabytes
      profile.consecutive_low_memory_samples = 0
      profile.p95_memory_bytes = 7.gigabytes # stale, would not qualify as low-memory

      decision = described_class.new(
        profile: profile,
        user_settings: user_settings,
        baseline_limit_bytes: 8.gigabytes,
        p95_memory_bytes: (8.gigabytes * AgentRunResourceProfile::LOW_MEMORY_HEADROOM_RATIO) - 64.megabytes
      ).call

      expect(decision.consecutive_low_memory_samples).to eq(1)
    end

    it "treats a brand-new profile (persisted p95 = 0) as eligible for a low-memory sample when the freshly computed p95 qualifies" do
      profile.recommended_memory_limit_bytes = 0
      profile.consecutive_low_memory_samples = 0
      profile.p95_memory_bytes = 0

      decision = described_class.new(
        profile: profile,
        user_settings: user_settings,
        baseline_limit_bytes: 4.gigabytes,
        p95_memory_bytes: 1.gigabyte
      ).call

      # 1GB is below 4GB * 0.6 = 2.4GB headroom threshold, so it should count
      # toward the consecutive counter rather than being short-circuited by
      # the stale persisted attribute.
      expect(decision.consecutive_low_memory_samples).to eq(1)
    end

    it "accrues consecutive low-memory samples against the held limit when baseline is derived from p95" do
      # Regression: with `baseline_limit_bytes = p95 * SAFETY_MULTIPLIER`
      # (the value RefreshForRun actually passes in production), scoring
      # the low-memory test against `target` was unsatisfiable because
      # `target ≈ p95 * 1.2` and `p95 > target * 0.6 = p95 * 0.72`. The
      # counter therefore never incremented and the held limit could
      # never drop. The hold branch must score against `previous_limit`
      # so sustained low-usage windows can authorize a downward tune.
      profile.recommended_memory_limit_bytes = 8.gigabytes
      profile.consecutive_low_memory_samples = 0
      profile.downward_tuning_count = 0
      p95_memory_bytes = 1.gigabyte

      decision = described_class.new(
        profile: profile,
        user_settings: user_settings,
        baseline_limit_bytes: (p95_memory_bytes * AgentRunResourceProfile::SAFETY_MULTIPLIER).ceil,
        p95_memory_bytes: p95_memory_bytes
      ).call

      # Held at 8 GB because no consecutive samples have banked yet.
      expect(decision.recommended_limit_bytes).to eq(8.gigabytes)
      # But the counter must have incremented — 1 GB <= 8 GB * 0.6 = 4.8 GB.
      expect(decision.consecutive_low_memory_samples).to eq(1)
      expect(decision.downward_tuning_count).to eq(0)
    end

    it "tunes downward after sustained low-memory windows when baseline tracks p95" do
      # End-to-end shape of the production path: every refresh passes
      # `baseline_limit_bytes = p95 * SAFETY_MULTIPLIER`. After enough
      # consecutive hold-branch samples, the next refresh must authorize
      # the downward move and collapse the held limit to the new baseline.
      profile.recommended_memory_limit_bytes = 8.gigabytes
      profile.consecutive_low_memory_samples = AgentRunResourceProfile::DOWNWARD_TUNING_MIN_SAMPLES
      profile.downward_tuning_count = 0
      p95_memory_bytes = 1.gigabyte

      decision = described_class.new(
        profile: profile,
        user_settings: user_settings,
        baseline_limit_bytes: (p95_memory_bytes * AgentRunResourceProfile::SAFETY_MULTIPLIER).ceil,
        p95_memory_bytes: p95_memory_bytes
      ).call

      expect(decision.recommended_limit_bytes).to eq((p95_memory_bytes * AgentRunResourceProfile::SAFETY_MULTIPLIER).ceil)
      expect(decision.downward_tuning_count).to eq(1)
      expect(decision.downward_tuned?).to be(true)
    end

    it "resets the consecutive counter inside the hold branch when the held limit is no longer comfortable" do
      # Symmetric guard: when the held limit is *not* comfortable anymore
      # (the workload grew back toward it), the cooldown must reset even
      # if `target` is unchanged. Otherwise a single quiet refresh could
      # bank a sample that later authorized an unsafe drop.
      profile.recommended_memory_limit_bytes = 8.gigabytes
      profile.consecutive_low_memory_samples = AgentRunResourceProfile::DOWNWARD_TUNING_MIN_SAMPLES - 1
      profile.downward_tuning_count = 0
      p95_memory_bytes = 1.gigabyte

      decision = described_class.new(
        profile: profile,
        user_settings: user_settings,
        baseline_limit_bytes: (p95_memory_bytes * AgentRunResourceProfile::SAFETY_MULTIPLIER).ceil,
        # p95 is now 5 GB — comfortably above 8 GB * 0.6 = 4.8 GB.
        p95_memory_bytes: 5.gigabytes
      ).call

      expect(decision.recommended_limit_bytes).to eq(8.gigabytes)
      expect(decision.consecutive_low_memory_samples).to eq(0)
    end
  end
end
