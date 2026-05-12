# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRun, :no_db do
  describe ".stale_running_cutoffs_by_goal" do
    it "uses the provided timeout map without querying Active Record state" do
      now = Time.zone.parse("2026-05-12 12:00:00 UTC")
      timeouts_by_goal = described_class::GOALS.index_with { 20.minutes }

      expect(
        described_class.stale_running_cutoffs_by_goal(
          now: now,
          timeouts_by_goal: timeouts_by_goal,
          default_timeout: 70.minutes
        )
      ).to eq(described_class::GOALS.index_with { now - 20.minutes })
    end
  end

  describe ".adaptive_stale_running_timeout" do
    it "caps adaptive timeouts at the legacy default" do
      expect(described_class.adaptive_stale_running_timeout({ count: 20, p95: 4_000 }))
        .to eq(described_class.default_stale_running_timeout)
    end
  end
end
