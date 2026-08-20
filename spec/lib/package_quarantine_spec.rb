# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("scripts/lib/package_quarantine")

RSpec.describe PackageQuarantine, :no_db do
  let(:now) { Time.utc(2026, 8, 19, 12, 0, 0) }

  def quarantine(minimum_age_hours: 72, skip: false)
    described_class.new(minimum_age_hours: minimum_age_hours, skip: skip, clock: -> { now })
  end

  # @spec TOOLCHAIN-PIN-050
  it "holds a release published inside the quarantine window" do
    expect(quarantine).to be_held(now - (2 * 3600))
  end

  # @spec TOOLCHAIN-PIN-050
  it "adopts a release published outside the quarantine window" do
    expect(quarantine).not_to be_held(now - (100 * 3600))
  end

  it "adopts a release published exactly at the boundary" do
    expect(quarantine).not_to be_held(now - (72 * 3600))
  end

  # Blocking every version whose registry withheld a publication time would
  # stall updates rather than make them safer.
  it "does not hold a release whose publication time is unknown" do
    expect(quarantine).not_to be_held(nil)
  end

  describe "when the check is skipped" do
    it "adopts a release published moments ago" do
      expect(quarantine(skip: true)).not_to be_held(now - 60)
    end

    it "treats a zero minimum age as skipping the check" do
      expect(quarantine(minimum_age_hours: 0)).to be_skip
    end
  end

  # @spec TOOLCHAIN-PIN-052
  describe "#cooldown_days" do
    it "expresses a whole-day policy as that many days" do
      expect(quarantine(minimum_age_hours: 72).cooldown_days).to eq(3)
    end

    # Rounding down would let a three-day cooldown satisfy a 73-hour policy,
    # quietly weakening the quarantine by up to a day.
    it "rounds a partial day up rather than away" do
      expect(quarantine(minimum_age_hours: 73).cooldown_days).to eq(4)
      expect(quarantine(minimum_age_hours: 1).cooldown_days).to eq(1)
    end

    # Zero is meaningful to Bundler: it overrides any per-source or global
    # cooldown, which an absent flag would inherit instead.
    it "is zero when the check is skipped, to override configured cooldowns" do
      expect(quarantine(skip: true).cooldown_days).to eq(0)
      expect(quarantine(minimum_age_hours: 0).cooldown_days).to eq(0)
    end
  end

  # @spec TOOLCHAIN-PIN-051
  describe "#hold_reason" do
    it "names the version, its age, and the threshold it missed" do
      reason = quarantine.hold_reason("rtk", "0.45.0", now - (3 * 3600))

      expect(reason).to eq("rtk 0.45.0 (3.0h old, minimum: 72h)")
    end

    it "returns nothing for a release it does not hold" do
      expect(quarantine.hold_reason("rtk", "0.45.0", now - (100 * 3600))).to be_nil
    end
  end
end
