# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::Strategies::AutoReview::Signals do
  describe ".from_scan" do
    it "normalizes an empty scan into an object with empty collections" do
      signals = described_class.from_scan(nil)

      expect(signals.triggers).to eq([])
      expect(signals.labels_to_remove).to eq([])
      expect(signals.counters).to include(draft_review: nil, followup: nil, review_goal_retry: nil)
    end

    it "symbolizes trigger keys and freezes each trigger" do
      signals = described_class.from_scan(
        "pr_number" => 42,
        "phase" => "draft",
        "triggers" => [
          { "type" => "paid_agent_review_pending", "active_run" => true }
        ]
      )

      expect(signals.pr_number).to eq(42)
      expect(signals.phase).to eq("draft")
      expect(signals.triggers.first[:type]).to eq("paid_agent_review_pending")
      expect(signals.triggers.first[:active_run]).to be true
      expect(signals.triggers.first).to be_frozen
    end

    it "captures counters for drafts, followups, and review-goal retries" do
      signals = described_class.from_scan(
        current_draft_review_count: 2,
        current_followup_count: 3,
        current_review_goal_retry_count: 1
      )

      expect(signals.draft_review_count).to eq(2)
      expect(signals.followup_count).to eq(3)
      expect(signals.review_goal_retry_count).to eq(1)
    end
  end

  describe "phase predicates" do
    it "treats draft and restarted as draft_phase?" do
      expect(described_class.from_scan(phase: "draft")).to be_draft_phase
      expect(described_class.from_scan(phase: "restarted")).to be_draft_phase
    end

    it "identifies ready and escalated phases" do
      expect(described_class.from_scan(phase: "ready")).to be_ready_phase
      expect(described_class.from_scan(phase: "escalated")).to be_escalated_phase
    end
  end

  describe "trigger lookup helpers" do
    subject(:signals) do
      described_class.from_scan(
        triggers: [
          { type: "paid_agent_review_pending" },
          { type: "ci_failure", details: [ "lint" ] }
        ]
      )
    end

    it "looks up a trigger by type regardless of string/symbol keys" do
      expect(signals.trigger(:paid_agent_review_pending)).to be_a(Hash)
      expect(signals.trigger?("paid_agent_review_pending")).to be true
      expect(signals.trigger?(:missing_trigger)).to be false
    end

    it "exposes the ordered list of trigger type strings" do
      expect(signals.trigger_types).to eq(%w[paid_agent_review_pending ci_failure])
    end

    it "computes trigger_types_excluding for gate-style filtering" do
      expect(signals.trigger_types_excluding("paid_agent_review_pending")).to eq([ "ci_failure" ])
    end
  end
end
