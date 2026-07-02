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
        baseline_limit_bytes: 64.gigabytes
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
        baseline_limit_bytes: 6.gigabytes
      ).call

      expect(decision.recommended_limit_bytes).to eq(6.gigabytes)
      expect(decision.capacity_blocked?).to be(false)
    end

    it "marks the profile capacity-blocked when OOMs persist near the ceiling" do
      profile.recommended_memory_limit_bytes = 15.gigabytes
      profile.oom_count = AgentRunResourceProfile::CAPACITY_BLOCKED_OOM_THRESHOLD
      profile.p95_memory_bytes = 14.gigabytes

      decision = described_class.new(
        profile: profile,
        user_settings: user_settings,
        baseline_limit_bytes: 17.gigabytes
      ).call

      expect(decision.capacity_blocked?).to be(true)
      expect(decision.capacity_blocked_at).to be_present
      expect(decision.recommended_limit_bytes).to eq(15.gigabytes)
    end

    it "does not grow past the existing limit once the profile is capacity-blocked" do
      profile.recommended_memory_limit_bytes = 16.gigabytes
      profile.oom_count = AgentRunResourceProfile::CAPACITY_BLOCKED_OOM_THRESHOLD
      profile.capacity_blocked = true
      profile.capacity_blocked_at = 1.minute.ago

      decision = described_class.new(
        profile: profile,
        user_settings: user_settings,
        baseline_limit_bytes: 20.gigabytes
      ).call

      expect(decision.recommended_limit_bytes).to eq(16.gigabytes)
      expect(decision.capacity_blocked?).to be(true)
    end

    it "clears capacity_blocked when the latest recommendation drops well below the ceiling" do
      profile.recommended_memory_limit_bytes = 4.gigabytes
      profile.oom_count = 0
      profile.capacity_blocked = true
      profile.capacity_blocked_at = 1.day.ago

      decision = described_class.new(
        profile: profile,
        user_settings: user_settings,
        baseline_limit_bytes: 4.gigabytes
      ).call

      expect(decision.capacity_blocked?).to be(false)
      expect(decision.capacity_blocked_at).to be_nil
    end

    it "tracks consecutive low-memory samples" do
      profile.recommended_memory_limit_bytes = 8.gigabytes
      profile.p95_memory_bytes = (8.gigabytes * AgentRunResourceProfile::LOW_MEMORY_HEADROOM_RATIO) - 64.megabytes

      decision = described_class.new(
        profile: profile,
        user_settings: user_settings,
        baseline_limit_bytes: 8.gigabytes
      ).call

      expect(decision.consecutive_low_memory_samples).to eq(1)
    end

    it "resets the consecutive counter when the latest sample is not low" do
      profile.recommended_memory_limit_bytes = 4.gigabytes
      profile.p95_memory_bytes = 4.gigabytes
      profile.consecutive_low_memory_samples = 4

      decision = described_class.new(
        profile: profile,
        user_settings: user_settings,
        baseline_limit_bytes: 5.gigabytes
      ).call

      expect(decision.consecutive_low_memory_samples).to eq(0)
    end

    it "refuses to tune downward until enough sustained low-memory samples exist" do
      profile.recommended_memory_limit_bytes = 8.gigabytes
      profile.consecutive_low_memory_samples = AgentRunResourceProfile::DOWNWARD_TUNING_MIN_SAMPLES - 1
      profile.downward_tuning_count = 0
      profile.p95_memory_bytes = (8.gigabytes * AgentRunResourceProfile::LOW_MEMORY_HEADROOM_RATIO) - 64.megabytes

      decision = described_class.new(
        profile: profile,
        user_settings: user_settings,
        baseline_limit_bytes: 5.gigabytes
      ).call

      expect(decision.recommended_limit_bytes).to eq(8.gigabytes)
      expect(decision.downward_tuning_count).to eq(0)
      expect(decision.downward_tuned?).to be(false)
    end

    it "tunes downward after the sustained low-memory threshold is reached" do
      profile.recommended_memory_limit_bytes = 8.gigabytes
      profile.consecutive_low_memory_samples = AgentRunResourceProfile::DOWNWARD_TUNING_MIN_SAMPLES + 1
      profile.downward_tuning_count = 0
      profile.p95_memory_bytes = (8.gigabytes * AgentRunResourceProfile::LOW_MEMORY_HEADROOM_RATIO) - 64.megabytes

      decision = described_class.new(
        profile: profile,
        user_settings: user_settings,
        baseline_limit_bytes: 5.gigabytes
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
        baseline_limit_bytes: 32.gigabytes
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
        baseline_limit_bytes: 64.megabytes
      ).call

      expect(decision.recommended_limit_bytes).to eq(512.megabytes)
    end
  end
end