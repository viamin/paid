# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::Strategies::AutoContinue::Signals do
  describe ".from_metadata" do
    it "returns nil when metadata is nil" do
      expect(described_class.from_metadata(nil)).to be_nil
    end

    it "returns nil when metadata has no lifecycle key" do
      expect(described_class.from_metadata({ scan: {} })).to be_nil
    end

    it "builds signals from lifecycle metadata" do
      lifecycle = {
        issue_id: 1, pr_number: 42, phase: "draft",
        active_run_exists: true, operational_failure_breaker: false,
        draft_review_limit_reached: false, consecutive_draft_failures_breaker: false,
        review_goal_retry_limit_requires_escalation: false,
        followup_limit_reached: false, escalation_dismissed: false,
        owner_reviewer_login: "alice", escalation_reason: nil, draft: true
      }
      scan = { triggers: [] }
      signals = described_class.from_metadata(lifecycle: lifecycle, scan: scan)

      expect(signals).to have_attributes(
        issue_id: 1, pr_number: 42, phase: "draft",
        active_run_exists: true, operational_failure_breaker: false,
        owner_reviewer_login: "alice", scan: scan
      )
    end

    it "coerces boolean fields strictly" do
      lifecycle = {
        issue_id: 1,
        pr_number: 42,
        phase: "ready",
        active_run_exists: nil,
        operational_failure_breaker: "yes",
        draft_review_limit_reached: 1,
        consecutive_draft_failures_breaker: false,
        review_goal_retry_limit_requires_escalation: false,
        followup_limit_reached: false,
        escalation_dismissed: false,
        draft: nil
      }

      signals = described_class.from_metadata(lifecycle: lifecycle)

      expect(signals.active_run_exists).to be false
      expect(signals.operational_failure_breaker).to be false
      expect(signals.draft_review_limit_reached).to be false
      expect(signals.draft).to be false
    end
  end

  describe "phase predicates" do
    def build_signals(phase:)
      described_class.from_metadata(lifecycle: {
        issue_id: 1, pr_number: 42, phase: phase,
        active_run_exists: false, operational_failure_breaker: false,
        draft_review_limit_reached: false, consecutive_draft_failures_breaker: false,
        review_goal_retry_limit_requires_escalation: false,
        followup_limit_reached: false, escalation_dismissed: false, draft: false
      })
    end

    it "reports draft_phase? for draft" do
      signals = build_signals(phase: "draft")
      expect(signals.draft_phase?).to be true
      expect(signals.ready_phase?).to be false
      expect(signals.escalated_phase?).to be false
    end

    it "reports draft_phase? for restarted" do
      signals = build_signals(phase: "restarted")
      expect(signals.draft_phase?).to be true
    end

    it "reports ready_phase? for ready" do
      signals = build_signals(phase: "ready")
      expect(signals.ready_phase?).to be true
      expect(signals.draft_phase?).to be false
    end

    it "reports escalated_phase? for escalated" do
      signals = build_signals(phase: "escalated")
      expect(signals.escalated_phase?).to be true
      expect(signals.ready_phase?).to be false
    end
  end
end
