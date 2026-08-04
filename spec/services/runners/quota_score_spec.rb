# frozen_string_literal: true

require "rails_helper"

RSpec.describe Runners::QuotaScore do
  describe ".call" do
    let(:user) { create(:user) }

    def record_quota!(runner_name:, remaining:, limit:, available: true)
      state = user.runner_states.find_or_create_by!(runner_name: runner_name)
      state.record_quota_status!(
        remaining: remaining,
        limit: limit,
        reset_at: 1.day.from_now,
        unit: "tokens",
        available: available,
        source: "monthly_token_budget"
      )
    end

    it "returns nil headroom for runners with no stored quota data" do
      result = described_class.call(runners: [ "claude" ], user: user)
      expect(result.headroom_for("claude")).to be_nil
    end

    it "computes headroom as remaining / limit" do
      record_quota!(runner_name: "claude", remaining: 300, limit: 1000)

      result = described_class.call(runners: [ "claude" ], user: user)
      expect(result.headroom_for("claude")).to be_within(0.001).of(0.3)
    end

    it "normalizes agent-type runner candidates back to their runner state key" do
      record_quota!(runner_name: "claude", remaining: 300, limit: 1000)

      result = described_class.call(runners: [ "claude_code" ], user: user)
      expect(result.headroom_for("claude_code")).to be_within(0.001).of(0.3)
    end

    it "returns nil headroom when available is false" do
      record_quota!(runner_name: "claude", remaining: 0, limit: 1000, available: false)

      result = described_class.call(runners: [ "claude" ], user: user)
      expect(result.headroom_for("claude")).to be_nil
    end

    # @spec RUNNER-QUOTA-004
    it "returns nil headroom when the stored snapshot is stale" do
      state = user.runner_states.find_or_create_by!(runner_name: "claude")
      state.record_quota_status!(
        remaining: 700,
        limit: 1000,
        reset_at: 1.day.from_now,
        unit: "tokens",
        available: true,
        source: "provider",
        checked_at: 2.hours.ago
      )

      result = described_class.call(runners: [ "claude" ], user: user)
      expect(result.headroom_for("claude")).to be_nil
    end

    it "clamps headroom to 1.0 when remaining exceeds limit" do
      record_quota!(runner_name: "claude", remaining: 1500, limit: 1000)

      result = described_class.call(runners: [ "claude" ], user: user)
      expect(result.headroom_for("claude")).to eq(1.0)
    end

    describe "Result#primary_low?" do
      it "returns true when primary headroom is below LOW_HEADROOM_THRESHOLD" do
        record_quota!(runner_name: "claude", remaining: 100, limit: 1000)

        result = described_class.call(runners: [ "claude" ], user: user)
        expect(result.primary_low?("claude")).to be true
      end

      it "returns false when primary headroom is at or above threshold" do
        record_quota!(runner_name: "claude", remaining: 250, limit: 1000)

        result = described_class.call(runners: [ "claude" ], user: user)
        expect(result.primary_low?("claude")).to be false
      end

      it "returns false when no quota data is available" do
        result = described_class.call(runners: [ "claude" ], user: user)
        expect(result.primary_low?("claude")).to be false
      end
    end

    describe "Result#better_fallback_for" do
      it "returns a fallback with high headroom when primary is low" do
        record_quota!(runner_name: "claude", remaining: 100, limit: 1000)
        record_quota!(runner_name: "codex", remaining: 800, limit: 1000)

        result = described_class.call(runners: [ "claude", "codex" ], user: user)
        expect(result.better_fallback_for("claude", [ "claude", "codex" ])).to eq("codex")
      end

      it "returns nil when primary is not low" do
        record_quota!(runner_name: "claude", remaining: 500, limit: 1000)
        record_quota!(runner_name: "codex", remaining: 800, limit: 1000)

        result = described_class.call(runners: [ "claude", "codex" ], user: user)
        expect(result.better_fallback_for("claude", [ "claude", "codex" ])).to be_nil
      end

      it "returns nil when no fallback meets FALLBACK_PREFERRED_THRESHOLD" do
        record_quota!(runner_name: "claude", remaining: 100, limit: 1000)
        record_quota!(runner_name: "codex", remaining: 300, limit: 1000)

        result = described_class.call(runners: [ "claude", "codex" ], user: user)
        expect(result.better_fallback_for("claude", [ "claude", "codex" ])).to be_nil
      end

      it "returns nil when primary has no quota data" do
        record_quota!(runner_name: "codex", remaining: 800, limit: 1000)

        result = described_class.call(runners: [ "claude", "codex" ], user: user)
        expect(result.better_fallback_for("claude", [ "claude", "codex" ])).to be_nil
      end
    end
  end
end
