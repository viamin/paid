# frozen_string_literal: true

require "rails_helper"

# @spec RUNNER-SCHED-003, RUNNER-SCHED-004, RUNNER-SCHED-005,
#   RUNNER-SCHED-007, RUNNER-SCHED-010
RSpec.describe Runners::TimeWindowCheck do
  let(:deepseek_config) do
    {
      "mode" => "block",
      "timezone" => "UTC",
      "windows" => [
        { "start_hour" => 1, "end_hour" => 4 },
        { "start_hour" => 6, "end_hour" => 10 }
      ]
    }
  end

  describe "#restrictions_enabled?" do
    it "returns false for nil config" do
      expect(described_class.new(nil)).not_to be_restrictions_enabled
    end

    it "returns false for empty config" do
      expect(described_class.new({})).not_to be_restrictions_enabled
    end

    it "returns false for config with mode but no windows" do
      config = { "mode" => "block" }
      check = described_class.new(config)
      expect(check).not_to be_restrictions_enabled
    end

    it "returns true for a valid config with windows" do
      expect(described_class.new(deepseek_config)).to be_restrictions_enabled
    end
  end

  describe "#blocked_at?" do
    it "returns true when current time is inside a window (block mode)" do
      # Hour 2 is inside {1,4}
      check = described_class.new(deepseek_config, now: Time.utc(2026, 1, 1, 2, 30))
      expect(check).to be_blocked_at
    end

    it "returns false when current time is outside all windows (block mode)" do
      # Hour 5 is between the two windows
      check = described_class.new(deepseek_config, now: Time.utc(2026, 1, 1, 5, 0))
      expect(check).not_to be_blocked_at
    end

    # @spec RUNNER-SCHED-003
    it "treats end_hour as exclusive" do
      # Hour 4 is NOT inside {1,4} (end exclusive)
      check = described_class.new(deepseek_config, now: Time.utc(2026, 1, 1, 4, 0))
      expect(check).not_to be_blocked_at
    end

    it "returns false for deprioritize mode even inside a window" do
      config = deepseek_config.merge("mode" => "deprioritize")
      check = described_class.new(config, now: Time.utc(2026, 1, 1, 2, 30))
      expect(check).not_to be_blocked_at
    end

    it "returns false for nil config" do
      check = described_class.new(nil, now: Time.utc(2026, 1, 1, 2, 30))
      expect(check).not_to be_blocked_at
    end
  end

  describe "#deprioritized_at?" do
    it "returns true when deprioritize mode and inside a window" do
      config = deepseek_config.merge("mode" => "deprioritize")
      check = described_class.new(config, now: Time.utc(2026, 1, 1, 7, 0))
      expect(check).to be_deprioritized_at
    end

    it "returns false when deprioritize mode but outside windows" do
      config = deepseek_config.merge("mode" => "deprioritize")
      check = described_class.new(config, now: Time.utc(2026, 1, 1, 5, 0))
      expect(check).not_to be_deprioritized_at
    end

    it "returns false for block mode" do
      check = described_class.new(deepseek_config, now: Time.utc(2026, 1, 1, 2, 30))
      expect(check).not_to be_deprioritized_at
    end
  end

  # @spec RUNNER-SCHED-004
  describe "wraparound windows" do
    let(:config) do
      { "mode" => "block", "timezone" => "UTC", "windows" => [ { "start_hour" => 22, "end_hour" => 2 } ] }
    end

    it "restricts before midnight" do
      check = described_class.new(config, now: Time.utc(2026, 1, 1, 23, 0))
      expect(check).to be_restricted_at
    end

    it "restricts after midnight" do
      check = described_class.new(config, now: Time.utc(2026, 1, 1, 1, 0))
      expect(check).to be_restricted_at
    end

    it "does not restrict between 2 and 22" do
      check = described_class.new(config, now: Time.utc(2026, 1, 1, 12, 0))
      expect(check).not_to be_restricted_at
    end
  end

  describe "timezone support" do
    it "interprets hours in the configured timezone" do
      # UTC 23:00 = Shanghai 07:00 (next day), which is inside {6,10} Shanghai
      config = deepseek_config.merge("timezone" => "Asia/Shanghai")
      check = described_class.new(config, now: Time.utc(2026, 1, 1, 23, 0))
      expect(check).to be_restricted_at
    end

    it "does not restrict when the local-equivalent hour is outside windows" do
      # UTC 02:00 = Shanghai 10:00, which is outside {1,4} and {6,10} (end exclusive)
      config = deepseek_config.merge("timezone" => "Asia/Shanghai")
      check = described_class.new(config, now: Time.utc(2026, 1, 1, 2, 0))
      expect(check).not_to be_restricted_at
    end
  end

  # @spec RUNNER-SCHED-010
  describe "#next_available_at" do
    it "returns nil when not currently restricted" do
      check = described_class.new(deepseek_config, now: Time.utc(2026, 1, 1, 5, 0))
      expect(check.next_available_at).to be_nil
    end

    it "returns nil when restrictions are not enabled" do
      check = described_class.new(nil, now: Time.utc(2026, 1, 1, 2, 0))
      expect(check.next_available_at).to be_nil
    end

    it "returns the start of the next non-restricted hour" do
      # At 2:30 UTC inside {1,4} → next available is 4:00 UTC
      check = described_class.new(deepseek_config, now: Time.utc(2026, 1, 1, 2, 30))
      expect(check.next_available_at).to eq(Time.utc(2026, 1, 1, 4, 0, 0))
    end

    it "returns the correct hour across the second window" do
      # At 8:00 UTC inside {6,10} → next available is 10:00 UTC
      check = described_class.new(deepseek_config, now: Time.utc(2026, 1, 1, 8, 0))
      expect(check.next_available_at).to eq(Time.utc(2026, 1, 1, 10, 0, 0))
    end

    it "handles wraparound windows" do
      config = { "mode" => "block", "timezone" => "UTC", "windows" => [ { "start_hour" => 22, "end_hour" => 2 } ] }
      # At 23:00, restricted until 02:00 next day
      check = described_class.new(config, now: Time.utc(2026, 1, 1, 23, 0))
      expect(check.next_available_at).to eq(Time.utc(2026, 1, 2, 2, 0, 0))
    end

    it "returns nil when all 24 hours are restricted (defense-in-depth)" do
      config = { "mode" => "block", "timezone" => "UTC",
        "windows" => [ { "start_hour" => 0, "end_hour" => 12 }, { "start_hour" => 12, "end_hour" => 0 } ] }
      check = described_class.new(config, now: Time.utc(2026, 1, 1, 2, 0))
      expect(check.next_available_at).to be_nil
    end
  end
end
