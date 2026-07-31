# frozen_string_literal: true

require "rails_helper"

# @spec RUNNER-SCHED-001, RUNNER-SCHED-002, RUNNER-SCHED-005, RUNNER-SCHED-007
RSpec.describe Runner, "#time_restrictions" do
  let(:user) { create(:user, :owner) }

  describe "validation" do
    it "accepts nil time_restrictions (no restrictions)" do
      runner = build(:runner, user: user, time_restrictions: nil)
      expect(runner).to be_valid
    end

    it "accepts a valid block-mode config" do
      runner = build(:runner, user: user, time_restrictions: {
        "mode" => "block", "timezone" => "UTC",
        "windows" => [ { "start_hour" => 1, "end_hour" => 4 } ]
      })
      expect(runner).to be_valid
    end

    it "accepts a valid deprioritize-mode config" do
      runner = build(:runner, user: user, time_restrictions: {
        "mode" => "deprioritize", "timezone" => "Asia/Shanghai",
        "windows" => [ { "start_hour" => 9, "end_hour" => 12 } ]
      })
      expect(runner).to be_valid
    end

    it "defaults timezone to UTC when omitted" do
      runner = build(:runner, user: user, time_restrictions: {
        "mode" => "block", "windows" => [ { "start_hour" => 1, "end_hour" => 4 } ]
      })
      expect(runner).to be_valid
    end

    it "rejects an invalid mode" do
      runner = build(:runner, user: user, time_restrictions: {
        "mode" => "pause", "timezone" => "UTC",
        "windows" => [ { "start_hour" => 1, "end_hour" => 4 } ]
      })
      expect(runner).not_to be_valid
      expect(runner.errors[:time_restrictions]).to be_present
    end

    it "rejects an unknown timezone" do
      runner = build(:runner, user: user, time_restrictions: {
        "mode" => "block", "timezone" => "Mars/Olympus",
        "windows" => [ { "start_hour" => 1, "end_hour" => 4 } ]
      })
      expect(runner).not_to be_valid
      expect(runner.errors[:time_restrictions]).to be_present
    end

    it "rejects mode without windows" do
      runner = build(:runner, user: user, time_restrictions: {
        "mode" => "block", "timezone" => "UTC", "windows" => []
      })
      expect(runner).not_to be_valid
    end

    it "rejects out-of-range hours" do
      runner = build(:runner, user: user, time_restrictions: {
        "mode" => "block", "timezone" => "UTC",
        "windows" => [ { "start_hour" => 0, "end_hour" => 25 } ]
      })
      expect(runner).not_to be_valid
    end

    it "rejects non-integer hours" do
      runner = build(:runner, user: user, time_restrictions: {
        "mode" => "block", "timezone" => "UTC",
        "windows" => [ { "start_hour" => "noon", "end_hour" => 4 } ]
      })
      expect(runner).not_to be_valid
    end

    it "rejects start_hour == end_hour (degenerate zero-width window)" do
      runner = build(:runner, user: user, time_restrictions: {
        "mode" => "block", "timezone" => "UTC",
        "windows" => [ { "start_hour" => 9, "end_hour" => 9 } ]
      })
      expect(runner).not_to be_valid
    end

    it "rejects more than 24 windows" do
      windows = (0..24).map { |h| { "start_hour" => h, "end_hour" => (h + 1) % 24 } }
      runner = build(:runner, user: user, time_restrictions: {
        "mode" => "block", "timezone" => "UTC", "windows" => windows
      })
      expect(runner).not_to be_valid
    end

    it "rejects windows that cover all 24 hours" do
      runner = build(:runner, user: user, time_restrictions: {
        "mode" => "block", "timezone" => "UTC",
        "windows" => [ { "start_hour" => 0, "end_hour" => 12 }, { "start_hour" => 12, "end_hour" => 0 } ]
      })
      expect(runner).not_to be_valid
      expect(runner.errors[:time_restrictions].join).to include("all 24 hours")
    end
  end

  describe "#blocked_by_time_window?" do
    it "returns false when no restrictions configured" do
      runner = build(:runner, user: user, time_restrictions: nil)
      expect(runner).not_to be_blocked_by_time_window(now: Time.utc(2026, 1, 1, 2, 0))
    end

    it "returns true when block-mode and inside a window" do
      runner = build(:runner, user: user, time_restrictions: {
        "mode" => "block", "timezone" => "UTC",
        "windows" => [ { "start_hour" => 1, "end_hour" => 4 } ]
      })
      expect(runner).to be_blocked_by_time_window(now: Time.utc(2026, 1, 1, 2, 0))
    end

    it "returns false when deprioritize-mode" do
      runner = build(:runner, user: user, time_restrictions: {
        "mode" => "deprioritize", "timezone" => "UTC",
        "windows" => [ { "start_hour" => 1, "end_hour" => 4 } ]
      })
      expect(runner).not_to be_blocked_by_time_window(now: Time.utc(2026, 1, 1, 2, 0))
    end
  end

  describe "#deprioritized_by_time_window?" do
    it "returns true when deprioritize-mode and inside a window" do
      runner = build(:runner, user: user, time_restrictions: {
        "mode" => "deprioritize", "timezone" => "UTC",
        "windows" => [ { "start_hour" => 6, "end_hour" => 10 } ]
      })
      expect(runner).to be_deprioritized_by_time_window(now: Time.utc(2026, 1, 1, 8, 0))
    end

    it "returns false when outside windows" do
      runner = build(:runner, user: user, time_restrictions: {
        "mode" => "deprioritize", "timezone" => "UTC",
        "windows" => [ { "start_hour" => 6, "end_hour" => 10 } ]
      })
      expect(runner).not_to be_deprioritized_by_time_window(now: Time.utc(2026, 1, 1, 5, 0))
    end
  end

  describe "#next_time_window_available_at" do
    it "returns the next non-restricted hour boundary" do
      runner = build(:runner, user: user, time_restrictions: {
        "mode" => "block", "timezone" => "UTC",
        "windows" => [ { "start_hour" => 1, "end_hour" => 4 } ]
      })
      expect(runner.next_time_window_available_at(now: Time.utc(2026, 1, 1, 2, 30)))
        .to eq(Time.utc(2026, 1, 1, 4, 0, 0))
    end

    it "returns nil when not currently restricted" do
      runner = build(:runner, user: user, time_restrictions: nil)
      expect(runner.next_time_window_available_at(now: Time.utc(2026, 1, 1, 5, 0))).to be_nil
    end
  end
end
